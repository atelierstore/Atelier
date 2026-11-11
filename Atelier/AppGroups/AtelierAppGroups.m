// AtelierAppGroups (#49): the library Atelier puts in apps it signs, which
// the app and each of its extensions load (SigningKit's AppGroupRedirect).
//
// Apple keeps an App Group's name unique across every team, so an app's own
// groups are its developer's, and iOS only hands an app the groups its
// signature lists. Most apps have their group's name written into their
// code, so this sends the names the app asks for elsewhere, from the
// AtelierAppGroups dictionary Atelier writes into each bundle's Info.plist:
//
// - With an Apple ID, to the names it gave the groups: a group's folder and
//   its settings are the renamed group's.
// - With a certificate, whose profile has App Groups of its own but not the
//   app's, to a folder of the app's own in one of those, from the
//   AtelierAppGroupFolders dictionary: the group's folder is that folder,
//   and its settings are kept in it, as iOS keeps a group's settings in the
//   group's folder, so they never mix with another app's.
//
// Settings the app saved under its own names while it had no group, which
// iOS kept in its own folder, move across once, from the app itself.
//
// Built without ARC: the replacements pass init's ownership on as it came.

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

@interface NSUserDefaults (AtelierAppGroups)
/// Foundation's own: settings named `suiteName`, kept in `container`'s
/// Library/Preferences, as a group's are in its folder.
- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

/// The group each of the app's groups is sent to, by the app's name. Set
/// once, before main.
static NSDictionary<NSString *, NSString *> *names;
/// The folder in that group each of the app's groups is kept in, by the
/// app's name, with a certificate. Set once, before main.
static NSDictionary<NSString *, NSString *> *folders;
/// Whether iOS keeps settings in those folders for this process, checked
/// once, before main.
static BOOL settingsInFolders;
/// Each folder, once found, by the app's name.
static NSMutableDictionary<NSString *, NSURL *> *found;

static IMP containerURL;
static IMP initWithSuiteName;
static IMP addSuiteNamed;
static IMP removeSuiteNamed;

/// The app's own name `group` stands for, as its Info.plist has it, or nil
/// when it isn't one of the app's.
static NSString *own(NSString *group) {
	if (![group isKindOfClass:[NSString class]]) return nil;
	if (names[group]) return group;
	for (NSString *name in names) {
		if ([name caseInsensitiveCompare:group] == NSOrderedSame) return name;
	}
	return nil;
}

/// The group's folder as iOS has it, with the original method.
static NSURL *groupFolder(NSString *group) {
	return ((NSURL *(*)(id, SEL, NSString *))containerURL)(NSFileManager.defaultManager, @selector(containerURLForSecurityApplicationGroupIdentifier:), group);
}

/// The folder kept for the app's group `name`, made with the Library
/// folders iOS makes in a group's, or nil when the certificate's group has
/// no folder.
static NSURL *folder(NSString *name) {
	@synchronized (found) {
		NSURL *url = found[name];
		if (url) return url;
		NSURL *group = groupFolder(names[name]);
		if (!group) return nil;
		url = [group URLByAppendingPathComponent:folders[name] isDirectory:YES];
		for (NSString *inside in @[@"Library/Caches", @"Library/Preferences"]) {
			[NSFileManager.defaultManager createDirectoryAtURL:[url URLByAppendingPathComponent:inside isDirectory:YES] withIntermediateDirectories:YES attributes:nil error:NULL];
		}
		found[name] = url;
		return url;
	}
}

/// Inside Foundation's own init, which may call the public one.
static __thread int initializing;

/// Settings named `suite`, kept in `container`.
static id initInFolder(id self, NSString *suite, NSURL *container) {
	initializing++;
	id defaults = [self _initWithSuiteName:suite container:container];
	initializing--;
	return defaults;
}

static NSURL *renamedContainerURL(id self, SEL _cmd, NSString *group) {
	NSString *name = own(group);
	if (!name) return ((NSURL *(*)(id, SEL, NSString *))containerURL)(self, _cmd, group);
	if (folders[name]) return folder(name);
	return ((NSURL *(*)(id, SEL, NSString *))containerURL)(self, _cmd, names[name]);
}

static id renamedInitWithSuiteName(id self, SEL _cmd, NSString *suite) {
	NSString *name = initializing ? nil : own(suite);
	if (!name) return ((id (*)(id, SEL, NSString *))initWithSuiteName)(self, _cmd, suite);
	if (!folders[name]) return ((id (*)(id, SEL, NSString *))initWithSuiteName)(self, _cmd, names[name]);
	// Else in its folder, or where iOS kept them before when it won't.
	NSURL *container = settingsInFolders ? folder(name) : nil;
	if (!container) return ((id (*)(id, SEL, NSString *))initWithSuiteName)(self, _cmd, suite);
	return initInFolder(self, name, container);
}

// A suite added to another's search list goes by its name alone, so with
// a certificate it stays where iOS keeps it.
static void renamedAddSuiteNamed(id self, SEL _cmd, NSString *suite) {
	NSString *name = own(suite);
	((void (*)(id, SEL, NSString *))addSuiteNamed)(self, _cmd, name && !folders[name] ? names[name] : suite);
}

static void renamedRemoveSuiteNamed(id self, SEL _cmd, NSString *suite) {
	NSString *name = own(suite);
	((void (*)(id, SEL, NSString *))removeSuiteNamed)(self, _cmd, name && !folders[name] ? names[name] : suite);
}

/// Puts `replacement` in place of `type`'s own method for `selector`, and
/// keeps that one in `original`. A method `type` only inherits is added to
/// it, so the superclass keeps its own.
static void replace(Class type, SEL selector, IMP replacement, IMP *original) {
	Method method = class_getInstanceMethod(type, selector);
	if (!method) return;
	*original = method_getImplementation(method);
	if (!class_addMethod(type, selector, replacement, method_getTypeEncoding(method))) {
		method_setImplementation(method, replacement);
	}
}

/// Whether iOS keeps settings in the app's folders: a value written there,
/// under a name like the group's, is in the file iOS keeps them in, read
/// back from the disk, as it would be lost otherwise. Checked in each
/// process, as it starts.
static BOOL keepsSettingsInFolders(void) {
	if (![NSUserDefaults instancesRespondToSelector:@selector(_initWithSuiteName:container:)]) return NO;
	NSURL *container = nil;
	NSString *suite = nil;
	for (NSString *name in [folders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
		if ((container = folder(name))) {
			suite = [name stringByAppendingString:@".atelier-check"];
			break;
		}
	}
	if (!container) return NO;
	NSString *check = NSUUID.UUID.UUIDString;
	NSUserDefaults *probe = initInFolder([NSUserDefaults alloc], suite, container);
	[probe setObject:check forKey:@"Check"];
	[probe synchronize];
	[probe release];
	NSString *file = [container URLByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", suite]].path;
	for (int attempt = 0; attempt < 10; attempt++) {
		if ([[NSDictionary dictionaryWithContentsOfFile:file][@"Check"] isEqual:check]) return YES;
		usleep(20000);
	}
	return NO;
}

/// Where the app's settings for its group `name` are now, or nil when
/// they're where iOS kept them before.
static NSString *movedTo(NSString *name) {
	if (!folders[name]) return names[name];
	if (!settingsInFolders || !folder(name)) return nil;
	return [names[name] stringByAppendingFormat:@"/%@", folders[name]];
}

/// Moves the settings the app saved under its groups' own names while it
/// had none, which iOS kept in its own folder, to where they're kept now,
/// once each, leaving what's there already. Only the app does, as its
/// extensions each had a folder of their own.
static void moveSettings(void) {
	if (![NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"]) return;
	NSString *record = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/AtelierAppGroups.plist"];
	NSMutableDictionary *moved = [NSMutableDictionary dictionaryWithContentsOfFile:record] ?: [NSMutableDictionary dictionary];
	BOOL changed = NO;
	for (NSString *name in names) {
		NSString *destination = movedTo(name);
		if (!destination || [moved[name] isEqual:destination]) continue;
		CFDictionaryRef before = CFPreferencesCopyMultiple(NULL, (CFStringRef)name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		NSDictionary *values = (NSDictionary *)before;
		if (values.count > 0) {
			NSUserDefaults *now = [[NSUserDefaults alloc] initWithSuiteName:name];
			for (NSString *key in values) {
				if (![now objectForKey:key]) [now setObject:values[key] forKey:key];
			}
			[now synchronize];
			[now release];
		}
		if (before) CFRelease(before);
		moved[name] = destination;
		changed = YES;
	}
	if (changed) [moved writeToFile:record atomically:YES];
}

__attribute__((constructor)) static void start(void) {
	@autoreleasepool {
		NSDictionary *info = NSBundle.mainBundle.infoDictionary;
		NSDictionary *listed = info[@"AtelierAppGroups"];
		if (![listed isKindOfClass:[NSDictionary class]]) return;
		NSDictionary *listedFolders = info[@"AtelierAppGroupFolders"];
		if (![listedFolders isKindOfClass:[NSDictionary class]]) listedFolders = nil;
		NSMutableDictionary<NSString *, NSString *> *validNames = [NSMutableDictionary dictionary];
		NSMutableDictionary<NSString *, NSString *> *validFolders = [NSMutableDictionary dictionary];
		for (id name in listed) {
			id group = listed[name];
			if (![name isKindOfClass:[NSString class]] || ![group isKindOfClass:[NSString class]]) continue;
			validNames[name] = group;
			id path = listedFolders[name];
			// A folder inside the group, never above it.
			if ([path isKindOfClass:[NSString class]] && [path length] > 0 && ![path hasPrefix:@"/"] && ![[path pathComponents] containsObject:@".."]) validFolders[name] = path;
		}
		if (validNames.count == 0) return;
		names = [validNames copy];
		folders = [validFolders copy];
		found = [[NSMutableDictionary alloc] init];

		replace([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:), (IMP)renamedContainerURL, &containerURL);
		replace([NSUserDefaults class], @selector(initWithSuiteName:), (IMP)renamedInitWithSuiteName, &initWithSuiteName);
		replace([NSUserDefaults class], @selector(addSuiteNamed:), (IMP)renamedAddSuiteNamed, &addSuiteNamed);
		replace([NSUserDefaults class], @selector(removeSuiteNamed:), (IMP)renamedRemoveSuiteNamed, &removeSuiteNamed);
		if (!containerURL) return;
		if (folders.count > 0) settingsInFolders = keepsSettingsInFolders();
		moveSettings();
	}
}
