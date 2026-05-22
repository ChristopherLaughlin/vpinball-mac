#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <csignal>

extern "C" char** g_argv;
extern "C" int g_argc;
extern "C" int WinMain(void*, void*, void*, int);

static const NSInteger kMaxRecentFiles = 10;
static NSString* const kRecentFilesKey = @"VPXRecentFiles";
static NSString* const kLastOpenDirKey = @"VPXLastOpenDir";
static NSString* const kTablesDirKey = @"VPXTablesDir";
static NSString* const kPerformanceTunedKey = @"VPXPerformanceTuned_v2";

static void ApplyMacPerformanceDefaults()
{
   if ([[NSUserDefaults standardUserDefaults] boolForKey:kPerformanceTunedKey])
      return;

   NSString* iniDir = [@"~/Library/Application Support/VPinballX/10.8" stringByExpandingTildeInPath];
   NSString* iniPath = [iniDir stringByAppendingPathComponent:@"VPinballX.ini"];

   [[NSFileManager defaultManager] createDirectoryAtPath:iniDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

   NSMutableString* ini = nil;
   BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:iniPath];
   if (fileExists) {
      NSError* readError = nil;
      ini = [NSMutableString stringWithContentsOfFile:iniPath encoding:NSUTF8StringEncoding error:&readError];
      if (!ini) {
         printf("Warning: could not read existing INI (%s), skipping performance tuning\n",
                [[readError localizedDescription] UTF8String]);
         return;
      }
   }

   if (!ini)
      ini = [NSMutableString string];

   auto setSetting = [&](NSString* section, NSString* key, NSString* value, NSString* comment) {
      NSString* keyPattern = [NSString stringWithFormat:@"\n%@ = ", key];
      if ([ini rangeOfString:keyPattern options:NSCaseInsensitiveSearch].location != NSNotFound)
         return;

      NSString* sectionHeader = [NSString stringWithFormat:@"[%@]", section];
      NSRange sectionRange = [ini rangeOfString:sectionHeader];
      if (sectionRange.location == NSNotFound) {
         [ini appendFormat:@"\n\n[%@]\n", section];
         sectionRange = [ini rangeOfString:sectionHeader];
      }

      NSUInteger insertPoint = sectionRange.location + sectionRange.length;
      NSString* entry = [NSString stringWithFormat:@"\n; %@ [macOS optimized]\n%@ = %@\n", comment, key, value];
      [ini insertString:entry atIndex:insertPoint];
   };

   setSetting(@"Player", @"PFReflection", @"3", @"Reflection: Static & Balls for better FPS");
   setSetting(@"Player", @"DynamicAO", @"0", @"Dynamic AO: disabled for better FPS");
   setSetting(@"Player", @"FXAA", @"1", @"Post-processed AA: Fast FXAA");
   setSetting(@"Player", @"MaxPrerenderedFrames", @"1", @"Prerender frames: 1 (Metal ignores >1, avoids wrong latency compensation)");
   setSetting(@"Player", @"MaxTexDimension", @"0", @"Texture size: unlimited (Apple unified memory has no VRAM bottleneck)");
   setSetting(@"Player", @"CompressTextures", @"1", @"BC texture compression: 4-8x bandwidth reduction on Apple Silicon");

   [ini writeToFile:iniPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

   [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kPerformanceTunedKey];
   printf("macOS performance defaults applied to %s\n", [iniPath UTF8String]);
}

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

static NSString* GetTablesDirectory()
{
   NSString* dir = [[NSUserDefaults standardUserDefaults] stringForKey:kTablesDirKey];
   if (dir && [[NSFileManager defaultManager] fileExistsAtPath:dir])
      return dir;
   return [@"~/Documents" stringByExpandingTildeInPath];
}

#pragma mark - Table Library Window

@interface VPXTableItem : NSObject
@property (nonatomic, copy) NSString* path;
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* size;
@property (nonatomic, copy) NSString* modified;
@end

@implementation VPXTableItem
@end

@interface VPXAppDelegate : NSObject <NSApplicationDelegate>
- (void)launchWithFile:(NSString*)path;
@end

@interface VPXTableLibrary : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSTextField* statusLabel;
@property (nonatomic, strong) NSTextField* searchField;
@property (nonatomic, strong) NSMutableArray<VPXTableItem*>* allTables;
@property (nonatomic, strong) NSMutableArray<VPXTableItem*>* filteredTables;
@property (nonatomic, assign) VPXAppDelegate* delegate;
@property (nonatomic, copy) NSString* currentDirectory;

- (void)show;
- (void)scanDirectory:(NSString*)directory;
@end

@implementation VPXTableLibrary

- (instancetype)init
{
   self = [super init];
   if (self) {
      _allTables = [NSMutableArray array];
      _filteredTables = [NSMutableArray array];
      _currentDirectory = GetTablesDirectory();
      [self createWindow];
   }
   return self;
}

- (void)createWindow
{
   NSRect frame = NSMakeRect(0, 0, 700, 500);
   self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskResizable |
                                                       NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
   self.window.title = @"VPinballX — Table Library";
   self.window.minSize = NSMakeSize(500, 350);
   [self.window center];

   NSView* contentView = self.window.contentView;

   // Toolbar area: search + buttons
   NSView* toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 44)];
   toolbar.translatesAutoresizingMaskIntoConstraints = NO;
   [contentView addSubview:toolbar];

   // Search field
   self.searchField = [[NSTextField alloc] initWithFrame:NSZeroRect];
   self.searchField.placeholderString = @"Filter tables...";
   self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
   self.searchField.bezelStyle = NSTextFieldRoundedBezel;
   self.searchField.target = self;
   self.searchField.action = @selector(filterChanged:);
   [toolbar addSubview:self.searchField];

   // Change folder button
   NSButton* folderBtn = [NSButton buttonWithTitle:@"Change Folder..."
                                            target:self
                                            action:@selector(chooseFolder:)];
   folderBtn.translatesAutoresizingMaskIntoConstraints = NO;
   folderBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
   [toolbar addSubview:folderBtn];

   // Browse button
   NSButton* browseBtn = [NSButton buttonWithTitle:@"Browse..."
                                            target:self
                                            action:@selector(browseForTable:)];
   browseBtn.translatesAutoresizingMaskIntoConstraints = NO;
   browseBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
   [toolbar addSubview:browseBtn];

   // Scroll view + table view
   NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
   scrollView.translatesAutoresizingMaskIntoConstraints = NO;
   scrollView.hasVerticalScroller = YES;
   scrollView.borderType = NSBezelBorder;
   [contentView addSubview:scrollView];

   self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
   self.tableView.dataSource = self;
   self.tableView.delegate = self;
   self.tableView.doubleAction = @selector(playSelected:);
   self.tableView.target = self;
   self.tableView.rowHeight = 28;
   self.tableView.usesAlternatingRowBackgroundColors = YES;
   self.tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

   NSTableColumn* nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
   nameCol.title = @"Table Name";
   nameCol.width = 350;
   nameCol.minWidth = 200;
   nameCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                   ascending:YES
                                                                    selector:@selector(localizedCaseInsensitiveCompare:)];
   [self.tableView addTableColumn:nameCol];

   NSTableColumn* sizeCol = [[NSTableColumn alloc] initWithIdentifier:@"size"];
   sizeCol.title = @"Size";
   sizeCol.width = 80;
   sizeCol.minWidth = 60;
   [self.tableView addTableColumn:sizeCol];

   NSTableColumn* modCol = [[NSTableColumn alloc] initWithIdentifier:@"modified"];
   modCol.title = @"Modified";
   modCol.width = 140;
   modCol.minWidth = 100;
   modCol.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"modified"
                                                                  ascending:NO
                                                                   selector:@selector(compare:)];
   [self.tableView addTableColumn:modCol];

   scrollView.documentView = self.tableView;

   // Status bar
   self.statusLabel = [NSTextField labelWithString:@""];
   self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
   self.statusLabel.font = [NSFont systemFontOfSize:11];
   self.statusLabel.textColor = [NSColor secondaryLabelColor];
   [contentView addSubview:self.statusLabel];

   // Play button
   NSButton* playBtn = [NSButton buttonWithTitle:@"Play"
                                          target:self
                                          action:@selector(playSelected:)];
   playBtn.translatesAutoresizingMaskIntoConstraints = NO;
   playBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
   playBtn.keyEquivalent = @"\r";
   [contentView addSubview:playBtn];

   // Layout
   [NSLayoutConstraint activateConstraints:@[
      [toolbar.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:8],
      [toolbar.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:12],
      [toolbar.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-12],
      [toolbar.heightAnchor constraintEqualToConstant:30],

      [self.searchField.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor],
      [self.searchField.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
      [self.searchField.widthAnchor constraintGreaterThanOrEqualToConstant:200],

      [browseBtn.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor],
      [browseBtn.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],

      [folderBtn.trailingAnchor constraintEqualToAnchor:browseBtn.leadingAnchor constant:-8],
      [folderBtn.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],

      [self.searchField.trailingAnchor constraintLessThanOrEqualToAnchor:folderBtn.leadingAnchor constant:-12],

      [scrollView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:8],
      [scrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:12],
      [scrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-12],
      [scrollView.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-8],

      [self.statusLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
      [self.statusLabel.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-10],

      [playBtn.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
      [playBtn.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-6],
   ]];

   // Recent tables section header
   [self scanDirectory:self.currentDirectory];
}

- (void)show
{
   [self.window makeKeyAndOrderFront:nil];
   [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - Directory Scanning

- (void)scanDirectory:(NSString*)directory
{
   self.currentDirectory = directory;
   self.statusLabel.stringValue = @"Scanning...";

   dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSMutableArray<VPXTableItem*>* tables = [NSMutableArray array];
      NSFileManager* fm = [NSFileManager defaultManager];
      NSDateFormatter* dateFmt = [[NSDateFormatter alloc] init];
      dateFmt.dateStyle = NSDateFormatterMediumStyle;
      dateFmt.timeStyle = NSDateFormatterShortStyle;

      NSDirectoryEnumerator* enumerator = [fm enumeratorAtPath:directory];
      NSString* file;
      while ((file = [enumerator nextObject])) {
         if ([[file.lowercaseString pathExtension] isEqualToString:@"vpx"]) {
            [enumerator skipDescendants];
            NSString* fullPath = [directory stringByAppendingPathComponent:file];
            NSDictionary* attrs = [fm attributesOfItemAtPath:fullPath error:nil];

            VPXTableItem* item = [[VPXTableItem alloc] init];
            item.path = fullPath;
            item.name = [file stringByDeletingPathExtension];

            unsigned long long bytes = [attrs fileSize];
            if (bytes > 1024 * 1024 * 1024)
               item.size = [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
            else if (bytes > 1024 * 1024)
               item.size = [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
            else
               item.size = [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];

            NSDate* modDate = [attrs fileModificationDate];
            item.modified = modDate ? [dateFmt stringFromDate:modDate] : @"";

            [tables addObject:item];
         }
      }

      [tables sortUsingComparator:^NSComparisonResult(VPXTableItem* a, VPXTableItem* b) {
         return [a.name localizedCaseInsensitiveCompare:b.name];
      }];

      dispatch_async(dispatch_get_main_queue(), ^{
         [self.allTables removeAllObjects];
         [self.allTables addObjectsFromArray:tables];
         [self applyFilter];
      });
   });
}

- (void)applyFilter
{
   NSString* query = self.searchField.stringValue;
   [self.filteredTables removeAllObjects];

   if (query.length == 0) {
      [self.filteredTables addObjectsFromArray:self.allTables];
   } else {
      for (VPXTableItem* item in self.allTables) {
         if ([item.name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
            [self.filteredTables addObject:item];
      }
   }

   [self.tableView reloadData];

   NSString* dirName = [self.currentDirectory lastPathComponent];
   self.statusLabel.stringValue = [NSString stringWithFormat:@"%ld table%s in %@",
                                   (long)self.filteredTables.count,
                                   self.filteredTables.count == 1 ? "" : "s",
                                   dirName];
}

#pragma mark - Actions

- (void)filterChanged:(id)sender
{
   [self applyFilter];
}

- (void)chooseFolder:(id)sender
{
   NSOpenPanel* panel = [NSOpenPanel openPanel];
   panel.message = @"Choose your tables folder";
   panel.canChooseDirectories = YES;
   panel.canChooseFiles = NO;
   panel.allowsMultipleSelection = NO;
   panel.directoryURL = [NSURL fileURLWithPath:self.currentDirectory];

   [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
      if (result == NSModalResponseOK) {
         NSString* path = [panel.URL path];
         [[NSUserDefaults standardUserDefaults] setObject:path forKey:kTablesDirKey];
         [self scanDirectory:path];
      }
   }];
}

- (void)browseForTable:(id)sender
{
   NSOpenPanel* panel = [NSOpenPanel openPanel];
   panel.message = @"Select a Visual Pinball Table";
   panel.allowsMultipleSelection = NO;
   panel.canChooseDirectories = NO;
   panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"vpx"]];

   NSString* lastDir = [[NSUserDefaults standardUserDefaults] stringForKey:kLastOpenDirKey];
   if (lastDir)
      panel.directoryURL = [NSURL fileURLWithPath:lastDir];

   [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
      if (result == NSModalResponseOK) {
         NSURL* fileURL = panel.URLs[0];
         NSString* path = [NSString stringWithUTF8String:[fileURL fileSystemRepresentation]];
         [[NSUserDefaults standardUserDefaults] setObject:[path stringByDeletingLastPathComponent] forKey:kLastOpenDirKey];
         [self.window close];
         [self.delegate launchWithFile:path];
      }
   }];
}

- (void)playSelected:(id)sender
{
   NSInteger row = self.tableView.selectedRow;
   if (row < 0 || row >= (NSInteger)self.filteredTables.count)
      return;

   VPXTableItem* item = self.filteredTables[row];
   [self.window close];
   [self.delegate launchWithFile:item.path];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
   return self.filteredTables.count;
}

#pragma mark - NSTableViewDelegate

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row
{
   NSString* identifier = tableColumn.identifier;
   NSTableCellView* cell = [tableView makeViewWithIdentifier:identifier owner:self];

   if (!cell) {
      cell = [[NSTableCellView alloc] init];
      cell.identifier = identifier;
      NSTextField* tf = [NSTextField labelWithString:@""];
      tf.translatesAutoresizingMaskIntoConstraints = NO;
      tf.lineBreakMode = NSLineBreakByTruncatingTail;
      [cell addSubview:tf];
      cell.textField = tf;
      [NSLayoutConstraint activateConstraints:@[
         [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
         [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
         [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      ]];
   }

   VPXTableItem* item = self.filteredTables[row];

   if ([identifier isEqualToString:@"name"]) {
      cell.textField.stringValue = item.name;
      cell.textField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
      cell.toolTip = item.path;
   } else if ([identifier isEqualToString:@"size"]) {
      cell.textField.stringValue = item.size;
      cell.textField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
      cell.textField.textColor = [NSColor secondaryLabelColor];
   } else if ([identifier isEqualToString:@"modified"]) {
      cell.textField.stringValue = item.modified;
      cell.textField.font = [NSFont systemFontOfSize:11];
      cell.textField.textColor = [NSColor secondaryLabelColor];
   }

   return cell;
}

- (void)tableView:(NSTableView*)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor*>*)oldDescriptors
{
   [self.filteredTables sortUsingDescriptors:tableView.sortDescriptors];
   [tableView reloadData];
}

@end

#pragma mark - App Delegate

@interface VPXAppDelegate ()
@property (nonatomic, strong) NSMenu* recentFilesMenu;
@property (nonatomic, strong) NSMenu* dockMenu;
@property (nonatomic, strong) VPXTableLibrary* tableLibrary;
@property (nonatomic, copy) NSString* currentTablePath;
@end

@implementation VPXAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
   ApplyMacPerformanceDefaults();
   [self setupMenuBar];
   [self setupDockMenu];

   if (g_argc == 1) {
      [self showTableLibrary];
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

- (void)showTableLibrary
{
   if (!self.tableLibrary) {
      self.tableLibrary = [[VPXTableLibrary alloc] init];
      self.tableLibrary.delegate = self;
   }
   [self.tableLibrary show];
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
   [fileMenu addItemWithTitle:@"Table Library" action:@selector(showTableLibrary) keyEquivalent:@"l"];
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

   [self.dockMenu addItemWithTitle:@"Table Library" action:@selector(showTableLibrary) keyEquivalent:@""];
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
