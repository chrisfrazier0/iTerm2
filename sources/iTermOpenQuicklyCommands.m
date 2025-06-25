//
//  iTermOpenQuicklyCommands.m
//  iTerm2
//
//  Created by George Nachman on 3/7/16.
//
//

#import "iTermOpenQuicklyCommands.h"

@implementation iTermOpenQuicklyCommand

@synthesize text = _text;

- (void)dealloc {
    [_text release];
    [super dealloc];
}
+ (NSString *)tipTitle {

    return [NSString stringWithFormat:@"Tip: Start your query with “/%@”", [self command]];
}

+ (NSString *)tipDetail {
    return [NSString stringWithFormat:@"Restricts results to %@", [self restrictionDescription]];
}

+ (NSString *)command {
    return nil;
}

+ (NSString *)restrictionDescription {
    return nil;
}

- (BOOL)supportsSessionLocation {
    return NO;
}

- (BOOL)supportsWindowLocation {
    return NO;
}

- (BOOL)supportsCreateNewTab {
    return NO;
}

- (BOOL)supportsChangeProfile {
    return NO;
}

- (BOOL)supportsOpenArrangement:(out BOOL *)tabsOnlyPtr {
    return NO;
}

- (BOOL)supportsScript {
    return NO;
}

- (BOOL)supportsColorPreset {
    return NO;
}

- (BOOL)supportsAction {
    return NO;
}

- (BOOL)supportsSnippet {
    return NO;
}

- (BOOL)supportsNamedMarks {
    return NO;
}

- (BOOL)supportsMenuItems {
    return NO;
}

- (BOOL)supportsBookmarks {
    return NO;
}

- (BOOL)supportsURLs {
    return NO;
}

@end

@implementation iTermOpenQuicklyInTabsWindowArrangementCommand

+ (NSString *)restrictionDescription {
    return @"window arrangements that open in tabs";
}

+ (NSString *)command {
    return @"A";
}

- (BOOL)supportsOpenArrangement:(out BOOL *)tabsOnlyPtr {
    *tabsOnlyPtr = YES;
    return YES;
}

@end

@implementation iTermOpenQuicklyWindowArrangementCommand

+ (NSString *)restrictionDescription {
    return @"window arrangements";
}

+ (NSString *)command {
    return @"a";
}

- (BOOL)supportsOpenArrangement:(out BOOL *)tabsOnlyPtr {
    *tabsOnlyPtr = NO;
    return YES;
}

@end

@implementation iTermOpenQuicklySearchSessionsCommand

+ (NSString *)restrictionDescription {
    return @"existing sessions";
}

+ (NSString *)command {
    return @"f";
}

- (BOOL)supportsSessionLocation {
    return YES;
}

@end

@implementation iTermOpenQuicklySearchWindowsCommand

+ (NSString *)restrictionDescription {
    return @"existing windows";
}

+ (NSString *)command {
    return @"w";
}

- (BOOL)supportsWindowLocation {
    return YES;
}

@end

@implementation iTermOpenQuicklySwitchProfileCommand

+ (NSString *)restrictionDescription {
    return @"switch profiles";
}

+ (NSString *)command {
    return @"p";
}

- (BOOL)supportsChangeProfile {
    return YES;
}

@end

@implementation iTermOpenQuicklyCreateTabCommand

+ (NSString *)restrictionDescription {
    return @"create tab";
}

+ (NSString *)command {
    return @"t";
}

- (BOOL)supportsCreateNewTab {
    return YES;
}

@end

@implementation iTermOpenQuicklyScriptCommand

+ (NSString *)restrictionDescription {
    return @"run script";
}

+ (NSString *)command {
    return @"s";
}

- (BOOL)supportsScript {
    return YES;
}

@end

@implementation iTermOpenQuicklyColorPresetCommand

+ (NSString *)restrictionDescription {
    return @"load color preset";
}

+ (NSString *)command {
    return @"c";
}

- (BOOL)supportsColorPreset {
    return YES;
}

@end

@implementation iTermOpenQuicklyNoCommand

- (BOOL)supportsSessionLocation {
    return YES;
}

- (BOOL)supportsCreateNewTab {
    return YES;
}

- (BOOL)supportsChangeProfile {
    return YES;
}

- (BOOL):(out BOOL *)tabsOnlyPtr {
    return YES;
}

- (BOOL)supportsScript {
    return YES;
}

- (BOOL)supportsColorPreset {
    return YES;
}

- (BOOL)supportsAction {
    return YES;
}

- (BOOL)supportsSnippet {
    return YES;
}

- (BOOL)supportsWindowLocation {
    return YES;
}

- (BOOL)supportsNamedMarks {
    return YES;
}

- (BOOL)supportsMenuItems {
    return YES;
}

- (BOOL)supportsBookmarks {
    return YES;
}

- (BOOL)supportsURLs {
    return YES;
}

@end

@implementation iTermOpenQuicklyActionCommand

+ (NSString *)restrictionDescription {
    return @"perform action";
}

+ (NSString *)command {
    return @":";
}

- (BOOL)supportsAction {
    return YES;
}

@end

@implementation iTermOpenQuicklySnippetCommand

+ (NSString *)restrictionDescription {
    return @"send snippet";
}

+ (NSString *)command {
    return @".";
}

- (BOOL)supportsSnippet {
    return YES;
}

@end

@implementation iTermOpenQuicklyBookmarkCommand

+ (NSString *)restrictionDescription {
    return @"open bookmark";
}

+ (NSString *)command {
    return @"b";
}

- (BOOL)supportsBookmarks {
    return YES;
}

@end
