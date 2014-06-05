//
//  MHConnectionWindowController.m
//  MongoHub
//
//  Created by Syd on 10-4-25.
//  Copyright 2010 MusicPeace.ORG. All rights reserved.
//

#import "Configure.h"
#import "NSString+Extras.h"
#import "NSProgressIndicator+Extras.h"
#import "MHConnectionWindowController.h"
#import "MHQueryWindowController.h"
#import "MHAddDBController.h"
#import "MHAddCollectionController.h"
#import "AuthWindowController.h"
#import "MHMysqlImportWindowController.h"
#import "MHMysqlExportWindowController.h"
#import "DatabasesArrayController.h"
#import "StatMonitorTableController.h"
#import "MHTunnel.h"
#import "MHServerItem.h"
#import "MHDatabaseItem.h"
#import "MHCollectionItem.h"
#import "SidebarBadgeCell.h"
#import "MHConnectionStore.h"
#import "MHDatabaseStore.h"
#import "MHFileExporter.h"
#import "MHFileImporter.h"
#import "MODHelper.h"
#import <mongo-objc-driver/MOD_public.h>
#import "MHStatusViewController.h"
#import "MHTabViewController.h"
#import "MHImportExportFeedback.h"

#define SERVER_STATUS_TOOLBAR_ITEM_TAG              0
#define DATABASE_STATUS_TOOLBAR_ITEM_TAG            1
#define COLLECTION_STATUS_TOOLBAR_ITEM_TAG          2
#define QUERY_TOOLBAR_ITEM_TAG                      3
#define MYSQL_IMPORT_TOOLBAR_ITEM_TAG               4
#define MYSQL_EXPORT_TOOLBAR_ITEM_TAG               5
#define FILE_IMPORT_TOOLBAR_ITEM_TAG                6
#define FILE_EXPORT_TOOLBAR_ITEM_TAG                7

#define DEFAULT_MONGO_IP                            @"127.0.0.1"

@interface MHConnectionWindowController()
@property (nonatomic, readwrite, retain) MHAddDBController *addDBController;
@property (nonatomic, readwrite, retain) MHAddCollectionController *addCollectionController;

- (void)updateToolbarItems;

- (void)closeMongoDB;
- (void)fetchServerStatusDelta;

- (MHDatabaseItem *)selectedDatabaseItem;
- (MHCollectionItem *)selectedCollectionItem;

- (MODQuery *)getDatabaseList;
- (MODQuery *)getCollectionListForDatabaseItem:(MHDatabaseItem *)databaseItem;

- (void)showDatabaseStatusWithDatabaseItem:(MHDatabaseItem *)databaseItem;
- (void)showCollectionStatusWithCollectionItem:(MHCollectionItem *)collectionItem;
@end

@implementation MHConnectionWindowController

@synthesize connectionStore = _connectionStore;
@synthesize client = _client;
@synthesize loaderIndicator;
@synthesize monitorButton;
@synthesize reconnectButton;
@synthesize statMonitorTableController;
@synthesize databases = _databases;
@synthesize sshTunnel = _sshTunnel;
@synthesize addDBController = _addDBController;
@synthesize addCollectionController = _addCollectionController;
@synthesize resultsTitle;
@synthesize bundleVersion;
@synthesize authWindowController;
@synthesize mysqlImportWindowController = _mysqlImportWindowController;
@synthesize mysqlExportWindowController = _mysqlExportWindowController;


- (id)init
{
    if (self = [super initWithWindowNibName:@"MHConnectionWindow"]) {
        self.databases = [[[NSMutableArray alloc] init] autorelease];
        _tabItemControllers = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self.window removeObserver:self forKeyPath:@"firstResponder"];
    [_tabViewController removeObserver:self forKeyPath:@"selectedTabIndex"];
    [_tabItemControllers release];
    [self closeMongoDB];
    self.connectionStore = nil;
    self.databases = nil;
    self.sshTunnel = nil;
    self.addDBController = nil;
    self.addCollectionController = nil;
    self.resultsTitle = nil;
    self.loaderIndicator = nil;
    self.reconnectButton = nil;
    self.monitorButton = nil;
    self.statMonitorTableController = nil;
    self.bundleVersion = nil;
    self.authWindowController = nil;
    self.mysqlImportWindowController = nil;
    self.mysqlExportWindowController = nil;
    [_statusViewController release];
    self.client = nil;
    [super dealloc];
}

- (void)closeMongoDB
{
    [_serverMonitorTimer invalidate];
    [_serverMonitorTimer release];
    _serverMonitorTimer = nil;
    self.client = nil;
    [_serverItem release];
    _serverItem = nil;
}

- (void)awakeFromNib
{
    NSView *tabView = _tabViewController.view;
    
    [[_splitView.subviews objectAtIndex:1] addSubview:tabView];
    tabView.frame = tabView.superview.bounds;
    _statusViewController = [[MHStatusViewController loadNewViewController] retain];
    [_tabViewController addTabItemViewController:_statusViewController];
    [_databaseCollectionOutlineView setDoubleAction:@selector(outlineViewDoubleClickAction:)];
    [self updateToolbarItems];
    
    if (self.connectionStore.userepl.intValue == 1) {
        self.window.title = [NSString stringWithFormat:@"%@ [%@]", self.connectionStore.alias, self.connectionStore.repl_name];
    } else {
        unsigned short hostPort = self.connectionStore.hostport.intValue;
        NSString *host = self.connectionStore.host.stringByTrimmingWhitespace;
        
        if (host.length == 0) {
            host = DEFAULT_MONGO_IP;
        }
        if (hostPort == 0 || hostPort == MODClient.defaultPort) {
            self.window.title = [NSString stringWithFormat:@"%@ [%@]", self.connectionStore.alias, host];
        } else {
            self.window.title = [NSString stringWithFormat:@"%@ [%@:%d]", self.connectionStore.alias, host, hostPort];
        }
    }
    [_tabViewController addObserver:self forKeyPath:@"selectedTabIndex" options:NSKeyValueObservingOptionNew context:nil];
    [self.window addObserver:self forKeyPath:@"firstResponder" options:NSKeyValueObservingOptionNew context:nil];
    _statusViewController.title = @"Connecting…";
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ((object == _tabViewController && [keyPath isEqualToString:@"selectedTabIndex"])
        || (object == self.window && [keyPath isEqualToString:@"firstResponder"] && self.window.firstResponder != _databaseCollectionOutlineView && self.window.firstResponder != self.window)) {
// update the outline view selection if the tab changed, or if the first responder changed
// don't do it if the first responder is the outline view or the windw, other we will lose the new user selection
        id selectedTab = _tabViewController.selectedTabItemViewController;
        
        if ([selectedTab isKindOfClass:[MHQueryWindowController class]]) {
            NSIndexSet *indexes = nil;
            MHDatabaseItem *databaseOutlineViewItem;
            MHCollectionItem *collectionOutlineViewItem;
            
            databaseOutlineViewItem = [_serverItem databaseItemWithName:[(MHQueryWindowController *)selectedTab collection].name];
            collectionOutlineViewItem = [databaseOutlineViewItem collectionItemWithName:[(MHQueryWindowController *)selectedTab collection].name];
            if (collectionOutlineViewItem) {
                [_databaseCollectionOutlineView expandItem:databaseOutlineViewItem];
                indexes = [[NSIndexSet alloc] initWithIndex:[_databaseCollectionOutlineView rowForItem:collectionOutlineViewItem]];
            } else if (databaseOutlineViewItem) {
                indexes = [[NSIndexSet alloc] initWithIndex:[_databaseCollectionOutlineView rowForItem:databaseOutlineViewItem]];
            }
            if (indexes) {
                [_databaseCollectionOutlineView selectRowIndexes:indexes byExtendingSelection:NO];
                [indexes release];
            }
        } else if ([selectedTab isKindOfClass:[MHStatusViewController class]]) {
            
        }
    }
}

- (void)didConnect
{
    [loaderIndicator stop];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(addDatabase:) name:kNewDBWindowWillClose object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(addCollection:) name:kNewCollectionWindowWillClose object:nil];
    reconnectButton.enabled = YES;
    monitorButton.enabled = YES;
    [self getDatabaseList];
    [self showServerStatus:nil];
}

- (void)didFailToConnectWithError:(NSError *)error
{
    [loaderIndicator stop];
    _statusViewController.title = [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
    NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"%@", error.localizedDescription);
}

- (void)connectToServer
{
    [loaderIndicator start];
    reconnectButton.enabled = NO;
    monitorButton.enabled = NO;
    if ((self.sshTunnel == nil || !self.sshTunnel.connected) && self.connectionStore.usessh.intValue == 1) {
        unsigned short hostPort;
        NSString *hostAddress;
        
        _sshTunnelPort = [MHTunnel findFreeTCPPort];
        if (!self.sshTunnel) {
            self.sshTunnel = [[[MHTunnel alloc] init] autorelease];
        }
        [self.sshTunnel setDelegate:self];
        [self.sshTunnel setUser:self.connectionStore.sshuser];
        [self.sshTunnel setHost:self.connectionStore.sshhost];
        [self.sshTunnel setPassword:self.connectionStore.sshpassword];
        [self.sshTunnel setKeyfile:self.connectionStore.sshkeyfile.stringByExpandingTildeInPath];
        [self.sshTunnel setPort:self.connectionStore.sshport.intValue];
        [self.sshTunnel setAliveCountMax:3];
        [self.sshTunnel setAliveInterval:30];
        [self.sshTunnel setTcpKeepAlive:YES];
        [self.sshTunnel setCompression:YES];
        hostPort = (unsigned short)self.connectionStore.hostport.intValue;
        if (hostPort == 0) {
            hostPort = MODClient.defaultPort;
        }
        hostAddress = self.connectionStore.host.stringByTrimmingWhitespace;
        if (hostAddress.length == 0) {
            hostAddress = @"127.0.0.1";
        }
        [self.sshTunnel addForwardingPortWithBindAddress:nil bindPort:_sshTunnelPort hostAddress:hostAddress hostPort:hostPort reverseForwarding:NO];
        [self.sshTunnel start];
        return;
    } else {
        NSString *uri;
        
        [self closeMongoDB];
        _serverItem = [[MHServerItem alloc] initWithClient:self.client delegate:self];
        if (self.connectionStore.adminuser.length > 0 && self.connectionStore.adminpass.length > 0) {
//            self.client.userName = self.connectionStore.adminuser;
//            self.client.password = self.connectionStore.adminpass;
//            if (self.connectionStore.defaultdb.length > 0) {
//                self.client.authDatabase = self.connectionStore.defaultdb;
//            } else {
//                self.client.authDatabase = @"admin";
//            }
        }
        if (self.connectionStore.userepl.intValue == 1) {
            uri = [[NSString alloc] initWithFormat:@"mongodb://%@", self.connectionStore.servers];
        } else {
            if (self.connectionStore.usessh.intValue == 1) {
                uri = [[NSString alloc] initWithFormat:@"127.0.0.1:%u", _sshTunnelPort];
            } else {
                NSString *host = self.connectionStore.host.stringByTrimmingWhitespace;
                NSNumber *hostport = self.connectionStore.hostport;
                
                if (host.length == 0) {
                    host = DEFAULT_MONGO_IP;
                }
                if (hostport.intValue == 0) {
                    hostport = [NSNumber numberWithInt:MODClient.defaultPort];
                }
                uri = [[NSString alloc] initWithFormat:@"mongodb://%@:%@", host, hostport];
            }
        }
        self.client = [MODClient clientWihtURLString:uri];
        _statusViewController.client = self.client;
        _statusViewController.connectionStore = self.connectionStore;
        [self.client serverStatusWithCallback:^(MODSortedMutableDictionary *serverStatus, MODQuery *mongoQuery) {
            if (mongoQuery.error) {
                [self didFailToConnectWithError:mongoQuery.error];
            } else {
                [self didConnect];
            }
        }];
        [uri release];
    }
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    NSString *appVersion = [[NSString alloc] initWithFormat:@"version: %@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"]];
    [bundleVersion setStringValue: appVersion];
    [appVersion release];
    [self connectToServer];
    [_databaseCollectionOutlineView setDoubleAction:@selector(sidebarDoubleAction:)];
}

- (void)sidebarDoubleAction:(id)sender
{
    [self query:sender];
}

- (IBAction)reconnect:(id)sender
{
    [self connectToServer];
}

- (void)windowWillClose:(NSNotification *)notification
{
    if (self.sshTunnel.isRunning) {
        [self.sshTunnel stop];
    }
    [self release];
}

- (MODQuery *)getDatabaseList
{
    MODQuery *result;
    
    [loaderIndicator start];
    result = [self.client databaseNamesWithCallback:^(NSArray *list, MODQuery *mongoQuery) {
        [loaderIndicator stop];
        if (list != nil) {
            if ([_serverItem updateChildrenWithList:list]) {
                [_databaseCollectionOutlineView reloadData];
            }
        } else if (self.connectionStore.defaultdb) {
            if ([_serverItem updateChildrenWithList:[NSArray arrayWithObject:self.connectionStore.defaultdb]]) {
                [_databaseCollectionOutlineView reloadData];
            }
        } else if (mongoQuery.error) {
            NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"%@", mongoQuery.error.localizedDescription);
        }
        
        [_databaseStoreArrayController clean:self.connectionStore databases:self.databases];
    }];
    return result;
}

- (void)getCollectionListForDatabaseName:(NSString *)databaseName
{
    MHDatabaseItem *databaseItem;
    
    databaseItem = [_serverItem databaseItemWithName:databaseName];
    if (databaseItem) {
        [self getCollectionListForDatabaseItem:databaseItem];
    }
}

- (MODQuery *)getCollectionListForDatabaseItem:(MHDatabaseItem *)databaseItem
{
    MODDatabase *mongoDatabase;
    MODQuery *result;
    
    mongoDatabase = databaseItem.database;
    [loaderIndicator start];
    result = [mongoDatabase fetchCollectionListWithCallback:^(NSArray *collectionList, MODQuery *mongoQuery) {
        MHDatabaseItem *databaseItem;
        
        [loaderIndicator stop];
        databaseItem = [_serverItem databaseItemWithName:mongoDatabase.name];
        if (collectionList && databaseItem) {
            if ([databaseItem updateChildrenWithList:collectionList]) {
                [_databaseCollectionOutlineView reloadData];
            }
        } else if (mongoQuery.error) {
            NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"%@", mongoQuery.error.localizedDescription);
        }
    }];
    return result;
}

- (void)showDatabaseStatusWithDatabaseItem:(MHDatabaseItem *)databaseItem
{
    if (_statusViewController == nil) {
        _statusViewController = [[MHStatusViewController loadNewViewController] retain];
        _statusViewController.client = self.client;
        _statusViewController.connectionStore = self.connectionStore;
        [_tabViewController addTabItemViewController:_statusViewController];
    }
    [_statusViewController showDatabaseStatusWithDatabaseItem:databaseItem];
}

- (void)showCollectionStatusWithCollectionItem:(MHCollectionItem *)collectionItem
{
    if (_statusViewController == nil) {
        _statusViewController = [[MHStatusViewController loadNewViewController] retain];
        _statusViewController.client = self.client;
        _statusViewController.connectionStore = self.connectionStore;
        [_tabViewController addTabItemViewController:_statusViewController];
    }
    [_statusViewController showCollectionStatusWithCollectionItem:collectionItem];
}

- (IBAction)showServerStatus:(id)sender 
{
    if (_statusViewController == nil) {
        _statusViewController = [[MHStatusViewController loadNewViewController] retain];
        _statusViewController.client = self.client;
        _statusViewController.connectionStore = self.connectionStore;
        [_tabViewController addTabItemViewController:_statusViewController];
    }
    [_statusViewController showServerStatus];
}

- (IBAction)showDatabaseStatus:(id)sender 
{
    [self showDatabaseStatusWithDatabaseItem:self.selectedDatabaseItem];
}

- (IBAction)showCollStats:(id)sender 
{
    [self showCollectionStatusWithCollectionItem:self.selectedCollectionItem];
}

- (void)outlineViewDoubleClickAction:(id)sender
{
    NSLog(@"test");
}

- (void)menuWillOpen:(NSMenu *)menu
{
    if (menu == createCollectionOrDatabaseMenu) {
        [menu itemWithTag:2].enabled = self.selectedDatabaseItem != nil;
    }
}

- (IBAction)createDatabase:(id)sender
{
    if (!self.addDBController) {
        self.addDBController = [[[MHAddDBController alloc] init] autorelease];
    }
    self.addDBController.conn = self.connectionStore;
    [self.addDBController modalForWindow:self.window];
}

- (IBAction)createCollection:(id)sender
{
    if (self.selectedDatabaseItem) {
        [self createCollectionForDatabaseName:self.selectedDatabaseItem.database.name];
    }
}

- (void)createCollectionForDatabaseName:(NSString *)databaseName
{
    if (!self.addCollectionController) {
        self.addCollectionController = [[[MHAddCollectionController alloc] init] autorelease];
    }
    self.addCollectionController.dbname = databaseName;
    [self.addCollectionController modalForWindow:self.window];
}

- (void)addDatabase:(NSNotification *)notification
{
    if (!notification.object) {
        return;
    }
    [[self.client databaseForName:[notification.object objectForKey:@"dbname"]] statsWithCallback:nil];
    [self getDatabaseList];
    self.addDBController = nil;
}

- (void)addCollection:(NSNotification *)notification
{
    if (!notification.object) {
        return;
    }
    NSString *collectionName = [notification.object objectForKey:@"collectionname"];
    MODDatabase *mongoDatabase;
    
    mongoDatabase = self.selectedDatabaseItem.database;
    [loaderIndicator start];
    [mongoDatabase createCollectionWithName:collectionName callback:^(MODQuery *mongoQuery) {
        [loaderIndicator stop];
        if (mongoQuery.error) {
            NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"%@", mongoQuery.error.localizedDescription);
        }
        [self getCollectionListForDatabaseName:mongoDatabase.name];
    }];
    self.addCollectionController = nil;
}

- (IBAction)dropDatabaseOrCollection:(id)sender
{
    if (self.selectedCollectionItem) {
        [self dropWarning:[NSString stringWithFormat:@"COLLECTION:%@", [[self.selectedCollectionItem collection] absoluteName]]];
    } else {
        [self dropWarning:[NSString stringWithFormat:@"DB:%@", self.selectedDatabaseItem.database]];
    }
}

- (void)dropCollection:(MODCollection *)collection
{
    if (collection) {
        NSString *databaseName = collection.database.name;
        
        [loaderIndicator start];
        [collection dropWithCallback:^(MODQuery *mongoQuery) {
            [loaderIndicator stop];
            if (mongoQuery.error) {
                NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"%@", mongoQuery.error.localizedDescription);
            } else {
                [self getCollectionListForDatabaseName:databaseName];
            }
        }];
    }
}

- (void)keyDown:(NSEvent *)theEvent
{
    if ([theEvent.charactersIgnoringModifiers isEqualToString:@"w"] && (theEvent.modifierFlags & NSDeviceIndependentModifierFlagsMask) == (NSUInteger)(NSCommandKeyMask | NSControlKeyMask)) {
        MHTabItemViewController *tabItemViewController;
        
        tabItemViewController = _tabViewController.selectedTabItemViewController;
        if ([tabItemViewController isKindOfClass:[MHQueryWindowController class]]) {
            [_tabItemControllers removeObjectForKey:[[(MHQueryWindowController *)tabItemViewController collection] absoluteName]];
        } else if (tabItemViewController == _statusViewController) {
            [_statusViewController release];
            _statusViewController = nil;
        }
        [_tabViewController removeTabItemViewController:tabItemViewController];
    } else {
        [super keyDown:theEvent];
    }
}

- (void)dropDatabase
{
    [loaderIndicator start];
    [self.selectedDatabaseItem.database dropWithCallback:^(MODQuery *mongoQuery) {
        [loaderIndicator stop];
        [self getDatabaseList];
        if (mongoQuery.error) {
            NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"%@", mongoQuery.error.localizedDescription);
        }
    }];
}

- (IBAction)query:(id)sender
{
    if (!self.selectedCollectionItem) {
        if (![_databaseCollectionOutlineView isItemExpanded:[_databaseCollectionOutlineView itemAtRow:[_databaseCollectionOutlineView selectedRow]]]) {
            [_databaseCollectionOutlineView expandItem:[_databaseCollectionOutlineView itemAtRow:[_databaseCollectionOutlineView selectedRow]] expandChildren:NO];
        } else {
            [_databaseCollectionOutlineView collapseItem:[_databaseCollectionOutlineView itemAtRow:[_databaseCollectionOutlineView selectedRow]]];
        }
    } else {
        MHQueryWindowController *queryWindowController;
        
        queryWindowController = [_tabItemControllers objectForKey:[[self.selectedCollectionItem collection] absoluteName]];
        if (queryWindowController == nil) {
            queryWindowController = [MHQueryWindowController loadQueryController];
            [_tabItemControllers setObject:queryWindowController forKey:[[self.selectedCollectionItem collection] absoluteName]];
            queryWindowController.collection = self.selectedCollectionItem.collection;
            queryWindowController.connectionStore = self.connectionStore;
            [_tabViewController addTabItemViewController:queryWindowController];
        }
        [queryWindowController select];
    }
}

- (IBAction)showAuth:(id)sender
{
    if (!self.selectedDatabaseItem)
    {
        NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, nil, nil, nil, @"Please choose a database!");
        return;
    }
    if (!authWindowController)
    {
        authWindowController = [[AuthWindowController alloc] init];
    }
    MHDatabaseStore *db = [_databaseStoreArrayController dbInfo:self.connectionStore name:self.selectedDatabaseItem.database.name];
    if (db) {
        [authWindowController.userTextField setStringValue:db.user];
        [authWindowController.passwordTextField setStringValue:db.password];
    }else {
        [authWindowController.userTextField setStringValue:@""];
        [authWindowController.passwordTextField setStringValue:@""];
    }
    authWindowController.conn = self.connectionStore;
    authWindowController.dbname = self.selectedDatabaseItem.database.name;
    [authWindowController showWindow:self];
}

- (void)dropWarningDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    if (returnCode == NSAlertSecondButtonReturn)
    {
        if (self.selectedCollectionItem) {
            [self dropCollection:self.selectedCollectionItem.collection];
        }else {
            [self dropDatabase];
        }
    }
}

- (void)dropWarning:(NSString *)msg
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"OK"];
    [alert setMessageText:[NSString stringWithFormat:@"Drop this %@?", msg]];
    [alert setInformativeText:[NSString stringWithFormat:@"Dropped %@ cannot be restored.", msg]];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert beginSheetModalForWindow:[self window] modalDelegate:self
                     didEndSelector:@selector(dropWarningDidEnd:returnCode:contextInfo:)
                        contextInfo:nil];
}

- (IBAction)startMonitor:(id)sender {
    if (!_serverMonitorTimer) {
        _serverMonitorTimer = [[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(fetchServerStatusDelta) userInfo:nil repeats:YES] retain];
        [self fetchServerStatusDelta];
    }
    [NSApp beginSheet:monitorPanel modalForWindow:self.window modalDelegate:self didEndSelector:@selector(monitorPanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
    NSLog(@"startMonitor");
}

- (IBAction)stopMonitor:(id)sender
{
    [NSApp endSheet:monitorPanel];
}

- (void)monitorPanelDidEnd:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    [monitorPanel close];
    [_serverMonitorTimer invalidate];
    [_serverMonitorTimer release];
    _serverMonitorTimer = nil;
}

static int percentage(NSNumber *previousValue, NSNumber *previousOutOfValue, NSNumber *value, NSNumber *outOfValue)
{
    double valueDiff = [value doubleValue] - [previousValue doubleValue];
    double outOfValueDiff = [outOfValue doubleValue] - [previousOutOfValue doubleValue];
    return (outOfValueDiff == 0) ? 0.0 : (valueDiff * 100.0 / outOfValueDiff);
}

- (void)fetchServerStatusDelta
{
    [resultsTitle setStringValue:[NSString stringWithFormat:@"Server %@:%@ stats", self.connectionStore.host, self.connectionStore.hostport]];
    [self.client serverStatusWithCallback:^(MODSortedMutableDictionary *serverStatus, MODQuery *mongoQuery) {
        [loaderIndicator stop];
        if (self.client == [mongoQuery.parameters objectForKey:@"client"]) {
            NSMutableDictionary *diff = [[NSMutableDictionary alloc] init];
            
            if (previousServerStatusForDelta) {
                NSNumber *number;
                NSDate *date;
                
                for (NSString *key in [[serverStatus objectForKey:@"opcounters"] allKeys]) {
                    number = [[NSNumber alloc] initWithInteger:[[[serverStatus objectForKey:@"opcounters"] objectForKey:key] integerValue] - [[[previousServerStatusForDelta objectForKey:@"opcounters"] objectForKey:key] integerValue]];
                    [diff setObject:number forKey:key];
                    [number release];
                }
                if ([[serverStatus objectForKey:@"mem"] objectForKey:@"mapped"]) {
                    [diff setObject:[[serverStatus objectForKey:@"mem"] objectForKey:@"mapped"] forKey:@"mapped"];
                }
                [diff setObject:[[serverStatus objectForKey:@"mem"] objectForKey:@"virtual"] forKey:@"vsize"];
                [diff setObject:[[serverStatus objectForKey:@"mem"] objectForKey:@"resident"] forKey:@"res"];
                number = [[NSNumber alloc] initWithInteger:[[[serverStatus objectForKey:@"extra_info"] objectForKey:@"page_faults"] integerValue] - [[[previousServerStatusForDelta objectForKey:@"extra_info"] objectForKey:@"page_faults"] integerValue]];
                [diff setObject:number forKey:@"faults"];
                [number release];
                number = [[NSNumber alloc] initWithInteger:percentage([[previousServerStatusForDelta objectForKey:@"globalLock"] objectForKey:@"lockTime"],
                                                                      [[previousServerStatusForDelta objectForKey:@"globalLock"] objectForKey:@"totalTime"],
                                                                      [[serverStatus objectForKey:@"globalLock"] objectForKey:@"lockTime"],
                                                                      [[serverStatus objectForKey:@"globalLock"] objectForKey:@"totalTime"])];
                [diff setObject:number forKey:@"locked"];
                [number release];
                number = [[NSNumber alloc] initWithInteger:percentage([[[previousServerStatusForDelta objectForKey:@"indexCounters"] objectForKey:@"btree"] objectForKey:@"misses"],
                                                                      [[[previousServerStatusForDelta objectForKey:@"indexCounters"] objectForKey:@"btree"] objectForKey:@"accesses"],
                                                                      [[[serverStatus objectForKey:@"indexCounters"] objectForKey:@"btree"] objectForKey:@"misses"],
                                                                      [[[serverStatus objectForKey:@"indexCounters"] objectForKey:@"btree"] objectForKey:@"accesses"])];
                [diff setObject:number forKey:@"misses"];
                [number release];
                date = [[NSDate alloc] init];
                [diff setObject:[[serverStatus objectForKey:@"connections"] objectForKey:@"current"] forKey:@"conn"];
                [diff setObject:date forKey:@"time"];
                [date release];
                [statMonitorTableController addObject:diff];
            }
            if (previousServerStatusForDelta) {
                [previousServerStatusForDelta release];
            }
            previousServerStatusForDelta = [serverStatus retain];
            [diff release];
        }
    }];
}

- (MHDatabaseItem *)selectedDatabaseItem
{
    MHDatabaseItem *result = nil;
    NSInteger index;
    
    index = [_databaseCollectionOutlineView selectedRow];
    if (index != NSNotFound) {
        id item;
        
        item = [_databaseCollectionOutlineView itemAtRow:index];
        if ([item isKindOfClass:[MHDatabaseItem class]]) {
            result = item;
        } else if ([item isKindOfClass:[MHCollectionItem class]]) {
            result = [item databaseItem];
        }
    }
    return result;
}

- (MHCollectionItem *)selectedCollectionItem
{
    MHCollectionItem *result = nil;
    NSInteger index;
    
    index = [_databaseCollectionOutlineView selectedRow];
    if (index != NSNotFound) {
        id item;
        
        item = [_databaseCollectionOutlineView itemAtRow:index];
        if ([item isKindOfClass:[MHCollectionItem class]]) {
            result = item;
        }
    }
    return result;
}

- (NSManagedObjectContext *)managedObjectContext
{
    return self.connectionStore.managedObjectContext;
}

- (void)updateToolbarItems
{
    for (NSToolbarItem *item in [_toolbar items]) {
        switch ([item tag]) {
            case DATABASE_STATUS_TOOLBAR_ITEM_TAG:
                item.enabled = self.selectedDatabaseItem != nil;
                break;
                
            case COLLECTION_STATUS_TOOLBAR_ITEM_TAG:
            case QUERY_TOOLBAR_ITEM_TAG:
            case MYSQL_IMPORT_TOOLBAR_ITEM_TAG:
            case MYSQL_EXPORT_TOOLBAR_ITEM_TAG:
            case FILE_IMPORT_TOOLBAR_ITEM_TAG:
            case FILE_EXPORT_TOOLBAR_ITEM_TAG:
                item.enabled = self.selectedCollectionItem != nil;
                break;
                
            default:
                break;
        }
    }
}

@end

@implementation MHConnectionWindowController (ImportExport)

- (void)importerExporterStopNotification:(NSNotification *)notification
{
    [NSNotificationCenter.defaultCenter removeObserver:self name:nil object:_importerExporter];
    [_importerExporter autorelease];
    _importerExporter = nil;
    [_importExportFeedback close];
    [_importExportFeedback autorelease];
    _importExportFeedback = nil;
}

- (void)exportSelectedCollectionToFilePath:(NSString *)filePath
{
    MHFileExporter *exporter;
    
    exporter = [[MHFileExporter alloc] initWithCollection:self.selectedCollectionItem.collection exportPath:filePath];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(importerExporterStopNotification:) name:MHImporterExporterStopNotification object:exporter];
    _importExportFeedback = [[MHImportExportFeedback alloc] initWithImporterExporter:exporter];
    _importExportFeedback.label = [NSString stringWithFormat:@"Exporting %@ to %@…", [self.selectedCollectionItem.collection absoluteName], [filePath lastPathComponent]];
    [_importExportFeedback start];
    [_importExportFeedback displayForWindow:self.window];
    [exporter export];
    _importerExporter = exporter;
}

- (void)importIntoSelectedCollectionFromFilePath:(NSString *)filePath
{
    MHFileImporter *importer;
    
    NSAssert(_importExportFeedback == nil, @"we should have no more feedback controller");
    importer = [[MHFileImporter alloc] initWithCollection:self.selectedCollectionItem.collection importPath:filePath];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(importerExporterStopNotification:) name:MHImporterExporterStopNotification object:importer];
    _importExportFeedback = [[MHImportExportFeedback alloc] initWithImporterExporter:importer];
    _importExportFeedback.label = [NSString stringWithFormat:@"Importing %@ into %@…", [filePath lastPathComponent], [self.selectedCollectionItem.collection absoluteName]];
    [_importExportFeedback start];
    [_importExportFeedback displayForWindow:self.window];
    [importer import];
    _importerExporter = importer;
}

- (IBAction)importFromMySQLAction:(id)sender
{
    if (self.selectedDatabaseItem == nil) {
        NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, NULL, NULL, nil, @"Please specify a database!");
        return;
    }
    if (!_mysqlImportWindowController) {
        _mysqlImportWindowController = [[MHMysqlImportWindowController alloc] init];
    }
    _mysqlImportWindowController.database = self.selectedDatabaseItem.database;
    if (self.selectedCollectionItem) {
        [_mysqlExportWindowController.collectionTextField setStringValue:[self.selectedCollectionItem.collection name]];
    }
    [_mysqlImportWindowController showWindow:self];
}

- (IBAction)exportToMySQLAction:(id)sender
{
    if (self.selectedCollectionItem == nil) {
        NSBeginAlertSheet(@"Error", @"OK", nil, nil, self.window, nil, NULL, NULL, nil, @"Please specify a collection!");
        return;
    }
    if (!_mysqlExportWindowController) {
        _mysqlExportWindowController = [[MHMysqlExportWindowController alloc] init];
    }
    _mysqlExportWindowController.mongoDatabase = self.selectedDatabaseItem.database;
    _mysqlExportWindowController.dbname = self.selectedDatabaseItem.database.name;
    if (self.selectedCollectionItem) {
        [_mysqlExportWindowController.collectionTextField setStringValue:[self.selectedCollectionItem.collection name]];
    }
    [_mysqlExportWindowController showWindow:self];
}

- (IBAction)importFromFileAction:(id)sender
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    
    [openPanel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result == NSOKButton) {
            // wait until the panel is closed to open the import feedback window
            [self performSelectorOnMainThread:@selector(importIntoSelectedCollectionFromFilePath:) withObject:[[openPanel URL] path] waitUntilDone:NO];
        }
    }];
}

- (IBAction)exportToFileAction:(id)sender
{
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    
    savePanel.nameFieldStringValue = [NSString stringWithFormat:@"%@-%@", self.selectedDatabaseItem.database, self.selectedCollectionItem.collection.name];
    [savePanel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result == NSOKButton) {
            // wait until the panel is closed to open the import feedback window
            [self performSelectorOnMainThread:@selector(exportSelectedCollectionToFilePath:) withObject:savePanel.URL.path waitUntilDone:NO];
        }
    }];
}

@end

@implementation MHConnectionWindowController(NSOutlineViewDataSource)

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
    if (!item) {
        return _serverItem.databaseItems.count;
    } else if ([item isKindOfClass:[MHDatabaseItem class]]) {
        return [item collectionItems].count;
    } else {
        return 0;
    }
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
    if (!item) {
        return [_serverItem.databaseItems objectAtIndex:index];
    } else if ([item isKindOfClass:[MHDatabaseItem class]]) {
        return [[item collectionItems] objectAtIndex:index];
    } else {
        return nil;
    }
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    return !item || [item isKindOfClass:[MHDatabaseItem class]];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
    return [item name];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
    if (self.selectedCollectionItem) {
        MHCollectionItem *collectionItem = self.selectedCollectionItem;
        
        [self getCollectionListForDatabaseItem:collectionItem.databaseItem];
        [self showCollectionStatusWithCollectionItem:collectionItem];
        if ([_tabItemControllers objectForKey:[collectionItem.collection absoluteName]]) {
            [[_tabItemControllers objectForKey:[collectionItem.collection absoluteName]] select];
        } else {
            [_statusViewController select];
        }
    } else if (self.selectedDatabaseItem) {
        MHDatabaseItem *databaseItem = self.selectedDatabaseItem;
        
        [self getCollectionListForDatabaseItem:databaseItem];
        [self showDatabaseStatusWithDatabaseItem:databaseItem];
    }
    [self updateToolbarItems];
    [self getDatabaseList];
}

- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    [cell setHasBadge:NO];
    [cell setIcon:nil];
    if ([item isKindOfClass:[MHCollectionItem class]]) {
        [cell setIcon:[NSImage imageNamed:@"collectionicon"]];
    } else if ([item isKindOfClass:[MHDatabaseItem class]]) {
        [cell setIcon:[NSImage imageNamed:@"dbicon"]];
        [cell setHasBadge:[item collectionItems].count > 0];
        [cell setBadgeCount:[item collectionItems].count];
    }
}

- (void)outlineViewItemWillExpand:(NSNotification *)notification
{
    [self getCollectionListForDatabaseItem:[[notification userInfo] objectForKey:@"NSObject"]];
}

@end


@implementation MHConnectionWindowController (MHServerItemDelegateCategory)

- (MODDatabase *)databaseWithDatabaseItem:(MHDatabaseItem *)item
{
    return [self.client databaseForName:item.name];
}

- (MODCollection *)collectionWithCollectionItem:(MHCollectionItem *)item
{
    return [[self databaseWithDatabaseItem:item.databaseItem] collectionForName:item.name];
}

@end

@implementation MHConnectionWindowController(MHTabViewControllerDelegate)

- (void)tabViewController:(MHTabViewController *)tabViewController didRemoveTabItem:(MHTabItemViewController *)tabItemViewController
{
    if (tabItemViewController == _statusViewController) {
        [_statusViewController release];
        _statusViewController = nil;
    } else {
        [_tabItemControllers removeObjectForKey:[(MHQueryWindowController *)tabItemViewController collection].absoluteName];
    }
}

@end

@implementation MHConnectionWindowController(MHTunnelDelegate)

- (void)tunnelDidConnect:(MHTunnel *)tunnel
{
    NSLog(@"SSH TUNNEL STATUS: CONNECTED");
    [self connectToServer];
}

- (void)tunnelDidFailToConnect:(MHTunnel *)tunnel withError:(NSError *)error;
{
    NSLog(@"SSH TUNNEL ERROR: %@", error);
    if (!tunnel.connected) {
        // after being connected, we don't really care about errors
        [self didFailToConnectWithError:error];
    }
}

@end
