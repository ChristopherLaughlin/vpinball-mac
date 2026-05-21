#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <csignal>

extern "C" char** g_argv;
extern "C" int g_argc;
extern "C" int WinMain(void*, void*, void*, int);

static const NSInteger kMaxRecentFiles = 10;
static NSString* const kRecentFilesKey = @"VPXRecentFiles";
static NSString* const kLastOpenDirKey = @"VPXLastOpenDir";
static NSString* const kWindowFrameKey = @"VPXMainWindowFrame";

void OnSignalHandler(int signum)
{
   printf("Exiting from signal: %d\n", signum);
   exit(-9999);
}

#pragma mark - Recent Files

static NSArray<NSString*>* LoadRecentFiles()
{
   NSArray* files = [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentFilesKey];
   return files ?: @[];
}

static void SaveRecentFiles(NSArray<NSString*>* files)
{
   [[NSUserDefaults standardUserDefaults] setObject:files forKey:kRecentFilesKey];
}

static void AddToRecentFiles(NSString* path)
{
   NSMutableArray* recent = [LoadRecentFiles() mutableCopy];
   [recent removeObject:path];
   [recent insertObject:path atIndex:0];
   while (recent.count > kMaxRecentFiles)
      [recent removeLastObject];
   SaveRecentFiles(recent);
}

#pragma mark - App Delegate

@interface VPXAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSMenu* recentFilesMenu;
@property (nonatomic, strong) NSMenu* dockMenu;
@property (nonatomic, copy) NSString* currentTablePath;
- (void)launchWithFile:(NSString*)path;
- (void)openDocument:(id)sender;
- (void)openRecentFile:(id)sender;
- (void)clearRecentFiles:(id)sender;
@end

@implementation VPXAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
   [self setupMenuBar];
   [self setupDockMenu];

   if (g_argc == 1) {
      [self showOpenPanel];
   } else {
      for (int i = 1; i < g_argc; i++) {
         if (strcmp(g_argv[i], "-play") == 0 && i + 1 < g_argc) {
            self.currentTablePath = [NSString stringWithUTF8String:g_argv[i + 1]];
            break;
         }
      }
      if (self.currentTablePath)
         AddToRecentFiles(self.currentTablePath);
      [self rebuildRecentFilesMenu];
      [self rebuildDockMenu];
      [self launchEngine];
   }
}

#pragma mark - Menu Bar

- (void)setupMenuBar
{
   NSMenu* mainMenu = [[NSMenu alloc] init];

   // Application menu
   NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
   NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"VPinballX"];
   [appMenu addItemWithTitle:@"About VPinballX" action:@selector(showAbout:) keyEquivalent:@""];
   [appMenu addItem:[NSMenuItem separatorItem]];
   [appMenu addItemWithTitle:@"Hide VPinballX" action:@selector(hide:) keyEquivalent:@"h"];
   NSMenuItem* hideOthers = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
   hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
   [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
   [appMenu addItem:[NSMenuItem separatorItem]];
   [appMenu addItemWithTitle:@"Quit VPinballX" action:@selector(terminate:) keyEquivalent:@"q"];
   appMenuItem.submenu = appMenu;
   [mainMenu addItem:appMenuItem];

   // File menu
   NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
   NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
   [fileMenu addItemWithTitle:@"Open Table..." action:@selector(openDocument:) keyEquivalent:@"o"];

   NSMenuItem* recentMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
   self.recentFilesMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
   recentMenuItem.submenu = self.recentFilesMenu;
   [fileMenu addItem:recentMenuItem];

   [fileMenu addItem:[NSMenuItem separatorItem]];
   [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
   fileMenuItem.submenu = fileMenu;
   [mainMenu addItem:fileMenuItem];

   // View menu
   NSMenuItem* viewMenuItem = [[NSMenuItem alloc] init];
   NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
   NSMenuItem* fullscreenItem = [viewMenu addItemWithTitle:@"Toggle Full Screen"
                                                    action:@selector(toggleFullScreen:)
                                             keyEquivalent:@"f"];
   fullscreenItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
   [viewMenu addItem:[NSMenuItem separatorItem]];
   [viewMenu addItemWithTitle:@"FPS Overlay (F11)" action:nil keyEquivalent:@""];
   [viewMenu addItemWithTitle:@"Settings (F12)" action:nil keyEquivalent:@""];
   viewMenuItem.submenu = viewMenu;
   [mainMenu addItem:viewMenuItem];

   // Window menu
   NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
   NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
   [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
   [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
   [windowMenu addItem:[NSMenuItem separatorItem]];
   [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
   windowMenuItem.submenu = windowMenu;
   [mainMenu addItem:windowMenuItem];
   [NSApp setWindowsMenu:windowMenu];

   // Help menu
   NSMenuItem* helpMenuItem = [[NSMenuItem alloc] init];
   NSMenu* helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
   [helpMenu addItemWithTitle:@"VPinballX Help" action:@selector(openHelp:) keyEquivalent:@"?"];
   [helpMenu addItem:[NSMenuItem separatorItem]];
   [helpMenu addItemWithTitle:@"Visual Pinball on GitHub" action:@selector(openGitHub:) keyEquivalent:@""];
   [helpMenu addItemWithTitle:@"VPForums" action:@selector(openForums:) keyEquivalent:@""];
   [helpMenu addItem:[NSMenuItem separatorItem]];
   [helpMenu addItemWithTitle:@"Open Settings Folder" action:@selector(openSettingsFolder:) keyEquivalent:@""];
   helpMenuItem.submenu = helpMenu;
   [mainMenu addItem:helpMenuItem];
   [NSApp setHelpMenu:helpMenu];

   [NSApp setMainMenu:mainMenu];
   [self rebuildRecentFilesMenu];
}

#pragma mark - Dock Menu

- (void)setupDockMenu
{
   self.dockMenu = [[NSMenu alloc] init];
   [self rebuildDockMenu];
}

- (void)rebuildDockMenu
{
   [self.dockMenu removeAllItems];

   [self.dockMenu addItemWithTitle:@"Open Table..." action:@selector(openDocument:) keyEquivalent:@""];

   NSArray<NSString*>* recent = LoadRecentFiles();
   if (recent.count > 0) {
      [self.dockMenu addItem:[NSMenuItem separatorItem]];
      NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:@"Recent Tables" action:nil keyEquivalent:@""];
      header.enabled = NO;
      [self.dockMenu addItem:header];

      NSInteger count = MIN(recent.count, (NSUInteger)5);
      for (NSInteger i = 0; i < count; i++) {
         NSString* path = recent[i];
         NSString* displayName = [[path lastPathComponent] stringByDeletingPathExtension];
         NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:displayName
                                                       action:@selector(openRecentFile:)
                                                keyEquivalent:@""];
         item.representedObject = path;
         [self.dockMenu addItem:item];
      }
   }
}

- (NSMenu*)applicationDockMenu:(NSApplication*)sender
{
   [self rebuildDockMenu];
   return self.dockMenu;
}

#pragma mark - Recent Files Menu

- (void)rebuildRecentFilesMenu
{
   [self.recentFilesMenu removeAllItems];
   NSArray<NSString*>* recent = LoadRecentFiles();

   for (NSString* path in recent) {
      NSString* displayName = [[path lastPathComponent] stringByDeletingPathExtension];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:displayName
                                                    action:@selector(openRecentFile:)
                                             keyEquivalent:@""];
      item.representedObject = path;
      item.toolTip = path;
      [self.recentFilesMenu addItem:item];
   }

   if (recent.count > 0) {
      [self.recentFilesMenu addItem:[NSMenuItem separatorItem]];
      [self.recentFilesMenu addItemWithTitle:@"Clear Menu" action:@selector(clearRecentFiles:) keyEquivalent:@""];
   }
}

#pragma mark - File Open

- (void)showOpenPanel
{
   NSOpenPanel* panel = [NSOpenPanel openPanel];
   panel.message = @"Select a Visual Pinball Table";
   panel.allowsMultipleSelection = NO;
   panel.canChooseDirectories = NO;
   panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"vpx"]];

   NSString* lastDir = [[NSUserDefaults standardUserDefaults] stringForKey:kLastOpenDirKey];
   if (lastDir)
      panel.directoryURL = [NSURL fileURLWithPath:lastDir];

   [panel beginWithCompletionHandler:^(NSInteger result) {
      if (result == NSModalResponseOK) {
         NSURL* fileURL = panel.URLs[0];
         NSString* path = [NSString stringWithUTF8String:[fileURL fileSystemRepresentation]];
         [[NSUserDefaults standardUserDefaults] setObject:[path stringByDeletingLastPathComponent] forKey:kLastOpenDirKey];
         [self launchWithFile:path];
      } else {
         exit(0);
      }
   }];
}

- (void)launchWithFile:(NSString*)path
{
   if (!path || path.length == 0)
      return;
   if (![[path.lowercaseString pathExtension] isEqualToString:@"vpx"])
      return;

   self.currentTablePath = path;
   AddToRecentFiles(path);
   [self rebuildRecentFilesMenu];
   [self rebuildDockMenu];

   char** new_argv = (char**)malloc(3 * sizeof(char*));
   new_argv[0] = g_argv[0];
   new_argv[1] = strdup("-play");
   new_argv[2] = strdup([path UTF8String]);
   g_argc = 3;
   g_argv = new_argv;

   [self launchEngine];
}

- (void)launchEngine
{
   int status = WinMain(NULL, NULL, NULL, 0);
   exit(status);
}

#pragma mark - Menu Actions

- (void)openDocument:(id)sender
{
   [self showOpenPanel];
}

- (void)openRecentFile:(id)sender
{
   NSMenuItem* item = (NSMenuItem*)sender;
   NSString* path = item.representedObject;
   if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      [self launchWithFile:path];
   } else {
      NSAlert* alert = [[NSAlert alloc] init];
      alert.messageText = @"File Not Found";
      alert.informativeText = [NSString stringWithFormat:@"The table \"%@\" could not be found.", [path lastPathComponent]];
      [alert addButtonWithTitle:@"OK"];
      [alert runModal];

      NSMutableArray* recent = [LoadRecentFiles() mutableCopy];
      [recent removeObject:path];
      SaveRecentFiles(recent);
      [self rebuildRecentFilesMenu];
      [self rebuildDockMenu];
   }
}

- (void)clearRecentFiles:(id)sender
{
   SaveRecentFiles(@[]);
   [self rebuildRecentFilesMenu];
   [self rebuildDockMenu];
}

- (void)showAbout:(id)sender
{
   NSDictionary* options = @{
      NSAboutPanelOptionApplicationName : @"VPinballX",
      NSAboutPanelOptionApplicationVersion : @"10.8.1",
      @"Copyright" : @"Copyright © 2025 VPinball Contributors.\nLicensed under GPLv3+.\n\nmacOS port by Chris Laughlin",
      NSAboutPanelOptionVersion : @"",
   };
   [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)openHelp:(id)sender
{
   [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/vpinball/vpinball/wiki"]];
}

- (void)openGitHub:(id)sender
{
   [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/vpinball/vpinball"]];
}

- (void)openForums:(id)sender
{
   [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://www.vpforums.org"]];
}

- (void)openSettingsFolder:(id)sender
{
   NSString* settingsPath = [@"~/Library/Application Support/VPinballX/10.8" stringByExpandingTildeInPath];
   [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:settingsPath]];
}

- (void)toggleFullScreen:(id)sender
{
   NSWindow* window = [NSApp mainWindow];
   if (window)
      [window toggleFullScreen:sender];
}

#pragma mark - File Association & Drag-and-Drop

- (BOOL)application:(NSApplication*)sender openFile:(NSString*)filename
{
   if (filename && filename.length > 0 &&
       [[filename.lowercaseString pathExtension] isEqualToString:@"vpx"]) {
      [self launchWithFile:filename];
      return YES;
   }
   return NO;
}

- (void)application:(NSApplication*)sender openFiles:(NSArray<NSString*>*)filenames
{
   for (NSString* filename in filenames) {
      if ([[filename.lowercaseString pathExtension] isEqualToString:@"vpx"]) {
         [self launchWithFile:filename];
         break;
      }
   }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
   return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
   return NSTerminateNow;
}

@end

int main(int argc, const char* argv[])
{
   @autoreleasepool {
      struct sigaction sigIntHandler;
      sigIntHandler.sa_handler = OnSignalHandler;
      sigemptyset(&sigIntHandler.sa_mask);
      sigIntHandler.sa_flags = 0;
      sigaction(SIGINT, &sigIntHandler, nullptr);

      g_argc = argc;
      g_argv = (char**)argv;

      NSApplication* vpxApp = [NSApplication sharedApplication];
      [vpxApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      VPXAppDelegate* delegate = [[VPXAppDelegate alloc] init];
      [vpxApp setDelegate:delegate];
      [vpxApp run];
   }
   return 0;
}
