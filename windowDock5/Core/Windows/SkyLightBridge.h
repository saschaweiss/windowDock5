// Core/Windows/Private/SkyLightBridge.h
#import <CoreGraphics/CoreGraphics.h>
typedef uint64_t CGSSpaceID;
typedef uint32_t CGSWindowID;
typedef int      CGSConnectionID;

extern CGSConnectionID _CGSDefaultConnection(void);

// CFArray<NSNumber(CGWindowID)>
extern CFArrayRef SLSCopyAllWindows(CGSConnectionID cid);

// windowList = CFArray<NSNumber(CGWindowID)>
// Rückgabe: gleiche Reihenfolge; je Eintrag entweder NSNumber(id64) oder CFArray<NSNumber(id64)>
extern CFArrayRef SLSCopySpacesForWindows(CGSConnectionID cid, int spaceMask, CFArrayRef windowList);

// Array von Dicts mit Display/Spaces-Infos (optional; wir brauchen es nicht zwingend)
extern CFArrayRef SLSCopyManagedDisplaySpaces(CGSConnectionID cid);

// Geometrie / Sichtbarkeit / Owner
extern int     SLSGetWindowBounds(CGSConnectionID cid, CGSWindowID wid, CGRect *outRect);
extern Boolean SLSWindowIsOnscreen(CGSConnectionID cid, CGSWindowID wid);
extern int     SLSGetWindowOwner(CGSConnectionID cid, CGSWindowID wid); // pid_t
 
