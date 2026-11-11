// AtelierAppGroups (#49): the library Atelier puts in apps it signs with an
// Apple ID, which the app and each of its extensions load
// (SigningKit's AppGroupRedirect).
//
// Apple keeps an App Group's name unique across every team, so the Apple ID
// has the app's groups under names of its own, and iOS only hands an app the
// groups its signature lists. Most apps have their group's name written into
// their code, so this sends the names the app asks for to the ones the Apple
// ID gave them, from the AtelierAppGroups dictionary Atelier writes into each
// bundle's Info.plist: for a group's folder and its settings, so the app and
// its widgets and extensions share their data again.
//
// Built without ARC: the replacements pass init's ownership on as it came.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/// The Apple ID's name for each group, by the app's. Set once, before main.
static NSDictionary<NSString *, NSString *> *names;

/// The Apple ID's name for `group`, or `group` when it isn't one of the app's.
static NSString *renamed(NSString *group) {
	if (![group isKindOfClass:[NSString class]]) return group;
	NSString *name = names[group];
	if (name) return name;
	for (NSString *own in names) {
		if ([own caseInsensitiveCompare:group] == NSOrderedSame) return names[own];
	}
	return group;
}

static IMP containerURL;
static NSURL *renamedContainerURL(id self, SEL _cmd, NSString *group) {
	return ((NSURL *(*)(id, SEL, NSString *))containerURL)(self, _cmd, renamed(group));
}

static IMP initWithSuiteName;
static id renamedInitWithSuiteName(id self, SEL _cmd, NSString *suite) {
	return ((id (*)(id, SEL, NSString *))initWithSuiteName)(self, _cmd, renamed(suite));
}

static IMP addSuiteNamed;
static void renamedAddSuiteNamed(id self, SEL _cmd, NSString *suite) {
	((void (*)(id, SEL, NSString *))addSuiteNamed)(self, _cmd, renamed(suite));
}

static IMP removeSuiteNamed;
static void renamedRemoveSuiteNamed(id self, SEL _cmd, NSString *suite) {
	((void (*)(id, SEL, NSString *))removeSuiteNamed)(self, _cmd, renamed(suite));
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

__attribute__((constructor)) static void start(void) {
	@autoreleasepool {
		NSDictionary *found = [NSBundle.mainBundle objectForInfoDictionaryKey:@"AtelierAppGroups"];
		if (![found isKindOfClass:[NSDictionary class]]) return;
		NSMutableDictionary<NSString *, NSString *> *valid = [NSMutableDictionary dictionary];
		for (id own in found) {
			id name = found[own];
			if ([own isKindOfClass:[NSString class]] && [name isKindOfClass:[NSString class]]) valid[own] = name;
		}
		if (valid.count == 0) return;
		names = [valid copy];

		replace([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:), (IMP)renamedContainerURL, &containerURL);
		replace([NSUserDefaults class], @selector(initWithSuiteName:), (IMP)renamedInitWithSuiteName, &initWithSuiteName);
		replace([NSUserDefaults class], @selector(addSuiteNamed:), (IMP)renamedAddSuiteNamed, &addSuiteNamed);
		replace([NSUserDefaults class], @selector(removeSuiteNamed:), (IMP)renamedRemoveSuiteNamed, &removeSuiteNamed);
	}
}
