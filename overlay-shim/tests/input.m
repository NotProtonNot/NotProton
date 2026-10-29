// Checks that -[WineApplication sendEvent:] drops game input while the overlay is open.
#import "../overlay_shim.m"
#import "check.h"

@interface WineApplication : NSObject
@property(nonatomic) int delivered;
- (void)sendEvent:(id)event;
@end

@implementation WineApplication
- (void)sendEvent:(id)event {
	(void)event;
	self.delivered++;
}
@end

@interface TestEvent : NSObject
@property(nonatomic) NSUInteger type;
@end
@implementation TestEvent
@end

static int delivered(WineApplication *app, NSUInteger type)
{
	TestEvent *event = [[TestEvent alloc] init];
	event.type = type;
	int before = app.delivered;
	[app sendEvent:event];
	[event release];
	return app.delivered - before;
}

int main(void)
{
	@autoreleasepool {
		WineApplication *app = [[WineApplication alloc] init];
		static const NSUInteger blocked[] = {
			event_left_down, event_left_up, event_right_down, event_right_up,
			event_mouse_moved, event_left_dragged, event_right_dragged,
			event_key_down, event_key_up, event_flags_changed, event_scroll_wheel,
			event_other_down, event_other_up, event_other_dragged,
		};
		// ApplicationDefined, SystemDefined, AppKitDefined
		static const NSUInteger passed[] = { 15, 14, 13 };

		CHECK(delivered(app, event_mouse_moved) == 1, "input is sent to the game when the overlay is not open");

		np_overlay_shim_set_active(1);
		for (size_t i = 0; i < sizeof(blocked) / sizeof(*blocked); i++)
			CHECK(delivered(app, blocked[i]) == 0, "event type %lu is not sent to the game when the overlay is open",
			      (unsigned long)blocked[i]);
		for (size_t i = 0; i < sizeof(passed) / sizeof(*passed); i++)
			CHECK(delivered(app, passed[i]) == 1, "event type %lu is still sent to the game when the overlay is open",
			      (unsigned long)passed[i]);
		[app sendEvent:nil];

		np_overlay_shim_set_active(0);
		for (size_t i = 0; i < sizeof(blocked) / sizeof(*blocked); i++)
			CHECK(delivered(app, blocked[i]) == 1, "event type %lu is sent to the game again after the overlay closes",
			      (unsigned long)blocked[i]);
		[app release];
	}
	printf("input is blocked while the overlay is open and comes back when it closes\n");
	return 0;
}
