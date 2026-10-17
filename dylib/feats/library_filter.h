#ifndef NOTPROTON_LIBRARY_FILTER_H
#define NOTPROTON_LIBRARY_FILTER_H

// A React child keeps the click logic separate from Steam's minified toolbar.
// Both modes use Steam's existing selected filter and observable filter model.
static const char NP_LIBRARY_BUTTON_JS[] =
"window.__NOTPROTON_LIBRARY_BUTTON__=function(props){\n"
"  const {jsx,Tooltip,Apple,Linux,disabled,selected,mode,select,linux}=props;\n"
"  const red=!linux&&selected&&mode==='windows';\n"
"  const hint=linux?'#GameList_View_Platform_Linux':red\n"
"    ?'Windows games without a Mac version (NotProton/CrossOver). Click to turn off this filter.'\n"
"    :'Native Mac games. Double-click to show Windows games without a Mac version.';\n"
"  const click=event=>{\n"
"    if(disabled)return;\n"
"    if(linux){select(!selected,'native');return;}\n"
"    if(event.detail===2)select(true,'windows');\n"
"    else if(!event.detail||event.detail===1)select(!selected,'native');\n"
"  };\n"
"  return jsx(Tooltip,{direction:'top',nDelayShowMS:2000,toolTipContent:hint,\n"
"    className:props.className,onClick:click,\n"
"    children:jsx(linux?Linux:Apple,{style:red?{color:'#ff453a',fill:'#ff453a'}:undefined})});\n"
"};\n";

#endif
