// No GPU needed to check who owns the pipelines.
#import "../overlay_shim.m"
#import "check.h"

static int live_pipelines;
static int live_devices;

@interface TestPipeline : NSObject
@property(nonatomic) NSUInteger format;
@end

@implementation TestPipeline
- (instancetype)init {
	self = [super init];
	if (self) live_pipelines++;
	return self;
}
- (void)dealloc {
	live_pipelines--;
	[super dealloc];
}
@end

@interface TestDevice : NSObject
@property(nonatomic) int builds;
@property(nonatomic) BOOL fail;
@end

@implementation TestDevice
- (instancetype)init {
	self = [super init];
	if (self) live_devices++;
	return self;
}
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor
                                    error:(NSError **)error {
	(void)error;
	self.builds++;
	if (self.fail) return nil;
	TestPipeline *state = [[TestPipeline alloc] init];
	state.format = descriptor.colorAttachments[0].pixelFormat;
	return state;
}
- (void)dealloc {
	live_devices--;
	[super dealloc];
}
@end

@class TestBuffer;
@interface TestEncoder : NSObject
@property(nonatomic, assign) TestBuffer *buffer;
@property(nonatomic, assign) TestPipeline *bound;
- (void)setRenderPipelineState:(TestPipeline *)state;
- (void)endEncoding;
@end

@interface TestBuffer : NSObject {
	NSMutableArray *handlers;
	NSMutableSet *metal_states;
}
@property(nonatomic) BOOL retainedReferences;
@property(nonatomic, readonly) TestEncoder *encoder;
@property(nonatomic, readonly) int handler_count;
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler;
- (void)usePipeline:(id)state;
- (void)complete;
@end

@implementation TestEncoder
- (void)setRenderPipelineState:(TestPipeline *)state {
	self.bound = state;
	[self.buffer usePipeline:state];
}
- (void)endEncoding {}
@end

@implementation TestBuffer
- (instancetype)init {
	self = [super init];
	if (self) {
		handlers = [[NSMutableArray alloc] init];
		metal_states = [[NSMutableSet alloc] init];
		_encoder = [[TestEncoder alloc] init];
		_encoder.buffer = self;
	}
	return self;
}
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler {
	id copied = [handler copy];
	[handlers addObject:copied];
	[copied release];
	_handler_count++;
}
- (void)usePipeline:(id)state {
	if (self.retainedReferences) [metal_states addObject:state];
}
- (void)complete {
	for (void (^handler)(id<MTLCommandBuffer>) in handlers)
		handler((id<MTLCommandBuffer>)self);
	[handlers removeAllObjects];
	[metal_states removeAllObjects];
}
- (void)dealloc {
	[handlers release];
	[metal_states release];
	[_encoder release];
	[super dealloc];
}
@end

@interface TestTexture : NSObject
@property(nonatomic) MTLPixelFormat pixelFormat;
@end
@implementation TestTexture
@end

static id test_render_encoder(id self, SEL selector, MTLRenderPassDescriptor *descriptor)
{
	(void)selector; (void)descriptor;
	return [(TestBuffer *)self encoder];
}

static void begin_pass(TestBuffer *buffer, MTLPixelFormat format)
{
	TestTexture *texture = [[TestTexture alloc] init];
	texture.pixelFormat = format;
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = (id<MTLTexture>)texture;
	next_render_encoder = test_render_encoder;
	hook_render_encoder(buffer, @selector(renderCommandEncoderWithDescriptor:), pass);
	[texture release];
}

static TestPipeline *new_base(TestDevice *device)
{
	MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
	descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	TestPipeline *state = [[TestPipeline alloc] init];
	state.format = MTLPixelFormatBGRA8Unorm;
	record_overlay_pipeline((id<MTLDevice>)device, descriptor, state);
	record_overlay_pipeline((id<MTLDevice>)device, descriptor, state);
	[descriptor release];
	return state;
}

static int variant_ownership(void)
{
	TestDevice *device = [[TestDevice alloc] init];
	MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
	descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	struct pipeline_entry entry = {
		.descriptor = descriptor, .device = (id<MTLDevice>)device,
		.base_format = MTLPixelFormatBGRA8Unorm
	};
	struct variant *variant = variant_for(&entry, MTLPixelFormatRGB10A2Unorm);
	CHECK(variant != NULL, "a variant is created");
	CHECK(variant_for(&entry, MTLPixelFormatRGB10A2Unorm) == variant && device.builds == 1,
	      "the same format reuses its variant");
	CHECK(descriptor.colorAttachments[0].pixelFormat == MTLPixelFormatBGRA8Unorm,
	      "building a variant restores the descriptor's format");
	[variant->state release];
	CHECK(live_pipelines == 0, "one release must destroy a new variant, %d still live", live_pipelines);
	[descriptor release];
	[device release];
	return 0;
}

static int buffer_lifetime(BOOL retained, BOOL discard)
{
	TestBuffer *buffer = [[TestBuffer alloc] init];
	buffer.retainedReferences = retained;
	@autoreleasepool {
		TestDevice *device = [[TestDevice alloc] init];
		TestPipeline *base = new_base(device);
		begin_pass(buffer, MTLPixelFormatRGB10A2Unorm);
		[buffer.encoder setRenderPipelineState:base];
		CHECK(buffer.encoder.bound != base && buffer.encoder.bound.format == MTLPixelFormatRGB10A2Unorm,
		      "a mismatched pipeline is substituted");
		[buffer.encoder setRenderPipelineState:base];
		CHECK(device.builds == 1, "repeated binds reuse the variant");
		[buffer.encoder endEncoding];
		[base release];
		[device release];
	}
	CHECK(live_devices == 0, "the cache releases its device after the base pipeline dies");
	CHECK(live_pipelines == 1, "only the in-flight variant remains, got %d", live_pipelines);
	CHECK(buffer.encoder.bound.format == MTLPixelFormatRGB10A2Unorm, "the GPU's variant remains valid");
	CHECK(buffer.handler_count == (retained ? 0 : 1), "unretained buffers need one completion handler");
	if (!discard) {
		[buffer complete];
		CHECK(live_pipelines == 0, "completion releases the variant even while the buffer lives");
	}
	[buffer release];
	CHECK(live_pipelines == 0, "discarding a buffer also releases its pipelines");
	return 0;
}

static int rebuilds(void)
{
	for (int i = 0; i < 64; i++) {
		@autoreleasepool {
			TestDevice *device = [[TestDevice alloc] init];
			TestPipeline *base = new_base(device);
			TestBuffer *buffer = [[TestBuffer alloc] init];
			begin_pass(buffer, MTLPixelFormatRGB10A2Unorm);
			device.fail = YES;
			[buffer.encoder setRenderPipelineState:base];
			CHECK(buffer.encoder.bound == base, "a failed compile keeps the original pipeline");
			device.fail = NO;
			[buffer.encoder setRenderPipelineState:base];
			CHECK(buffer.encoder.bound != base, "rebuild %d still gets a corrected pipeline", i);
			[buffer.encoder endEncoding];
			[buffer complete];
			[buffer release];
			[base release];
			[device release];
		}
		CHECK(live_pipelines == 0 && live_devices == 0, "rebuild %d leaves no cached objects", i);
	}
	return 0;
}

int main(void)
{
	@autoreleasepool {
		CHECK(variant_ownership() == 0, "variant ownership");
		CHECK(buffer_lifetime(NO, NO) == 0, "unretained buffer completion");
		CHECK(buffer_lifetime(NO, YES) == 0, "unretained buffer discard");
		CHECK(buffer_lifetime(YES, NO) == 0, "retained buffer completion");
		CHECK(buffer_lifetime(YES, YES) == 0, "retained buffer discard");
		CHECK(rebuilds() == 0, "pipeline rebuilds");
	}
	printf("pipeline ownership, completion, discard and rebuilds passed\n");
	return 0;
}
