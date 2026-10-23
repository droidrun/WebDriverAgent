/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBXCElementSnapshot.h"
#import "XCElementSnapshotDouble.h"
#import "XCUIApplication+FBHelpers.h"

static const unsigned long long FBTestTraitIsEditing = 1ULL << 21;

// A snapshot node with settable focus flags, traits, type and children.
@interface FBFocusSnapshotDouble : XCElementSnapshotDouble
@property (nonatomic, assign) BOOL fakeHasFocus;
@property (nonatomic, assign) BOOL fakeHasKeyboardFocus;
@property (nonatomic, assign) unsigned long long fakeTraits;
@property (nonatomic, assign) XCUIElementType fakeElementType;
@property (nonatomic, copy) NSString *fakeIdentifier;
@property (nonatomic, copy) NSArray *fakeChildren;
@end

@implementation FBFocusSnapshotDouble

- (BOOL)hasFocus { return self.fakeHasFocus; }
- (BOOL)hasKeyboardFocus { return self.fakeHasKeyboardFocus; }
- (UIAccessibilityTraits)traits { return (UIAccessibilityTraits)self.fakeTraits; }
- (XCUIElementType)elementType { return self.fakeElementType; }
- (NSString *)identifier { return self.fakeIdentifier ?: @""; }
- (NSArray *)children { return self.fakeChildren ?: @[]; }
- (BOOL)isSelected { return NO; }

@end

// fb_a11yNodeForSnapshot:... is private to the category; the test drives the whole walk.
@interface XCUIApplication (FBMobilerunFocusTesting)
+ (NSDictionary *)fb_a11yNodeForSnapshot:(id<FBXCElementSnapshot>)snapshot
                                   scale:(CGFloat)scale
                             packageName:(NSString *)bundleId
                                 context:(NSMutableDictionary *)context;
@end

@interface FBMobilerunFocusTests : XCTestCase
@end

@implementation FBMobilerunFocusTests

static FBFocusSnapshotDouble *FBNode(XCUIElementType type, NSString *identifier, NSArray *children)
{
  FBFocusSnapshotDouble *node = [FBFocusSnapshotDouble new];
  node.fakeElementType = type;
  node.fakeIdentifier = identifier;
  node.fakeChildren = children;
  return node;
}

static void FBCollectFocused(NSDictionary *node, NSMutableArray<NSString *> *focused)
{
  if ([node[@"isFocused"] boolValue]) {
    [focused addObject:node[@"resourceId"]];
  }
  for (NSDictionary *child in node[@"children"]) {
    FBCollectFocused(child, focused);
  }
}

// Runs the same walk fb_mobilerunA11yStateWithSnapshot:scale:truncated: runs.
static NSDictionary *FBWalk(id<FBXCElementSnapshot> root, NSMutableDictionary *context)
{
  id<FBXCElementSnapshot> focused = [XCUIApplication fb_mobilerunFocusedSnapshotInTree:root];
  if (nil != focused) {
    context[@"focusedSnapshot"] = focused;
  }
  return [XCUIApplication fb_a11yNodeForSnapshot:root scale:1 packageName:@"com.test" context:context];
}

- (void)testWebInputsReportingHasFocusAreNotFocused
{
  // WebKit sets hasFocus on every <input> of a page, focused or not.
  FBFocusSnapshotDouble *first = FBNode(XCUIElementTypeTextField, @"first", nil);
  FBFocusSnapshotDouble *second = FBNode(XCUIElementTypeTextField, @"second", nil);
  first.fakeHasFocus = YES;
  second.fakeHasFocus = YES;
  FBFocusSnapshotDouble *web = FBNode(XCUIElementTypeWebView, @"web", @[first, second]);
  FBFocusSnapshotDouble *app = FBNode(XCUIElementTypeApplication, @"app", @[web]);

  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  NSDictionary *tree = FBWalk((id<FBXCElementSnapshot>)app, context);

  NSMutableArray<NSString *> *focused = [NSMutableArray array];
  FBCollectFocused(tree, focused);
  XCTAssertEqualObjects(focused, @[]);
  XCTAssertNil(context[@"focusedElement"]);
  XCTAssertFalse([context[@"isEditable"] boolValue]);
}

- (void)testOnlyTheKeyboardFocusedWebInputIsFocused
{
  FBFocusSnapshotDouble *first = FBNode(XCUIElementTypeTextField, @"first", nil);
  FBFocusSnapshotDouble *second = FBNode(XCUIElementTypeTextField, @"second", nil);
  first.fakeHasFocus = YES;
  second.fakeHasFocus = YES;
  second.fakeHasKeyboardFocus = YES;
  FBFocusSnapshotDouble *app = FBNode(XCUIElementTypeApplication, @"app",
                                      @[FBNode(XCUIElementTypeWebView, @"web", @[first, second])]);

  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  NSDictionary *tree = FBWalk((id<FBXCElementSnapshot>)app, context);

  NSMutableArray<NSString *> *focused = [NSMutableArray array];
  FBCollectFocused(tree, focused);
  XCTAssertEqualObjects(focused, @[@"second"]);
  XCTAssertEqualObjects(context[@"focusedElement"][@"resourceId"], @"second");
  XCTAssertTrue([context[@"isEditable"] boolValue]);
}

- (void)testKeyboardFocusedFieldInASheetIsReported
{
  // A UIKit field never reports hasFocus on iPhone; only keyboard focus marks it.
  FBFocusSnapshotDouble *name = FBNode(XCUIElementTypeTextField, @"name", nil);
  name.fakeHasKeyboardFocus = YES;
  FBFocusSnapshotDouble *sheet = FBNode(XCUIElementTypeOther, @"sheet",
                                        @[FBNode(XCUIElementTypeCell, @"cell", @[name])]);
  FBFocusSnapshotDouble *keyboard = FBNode(XCUIElementTypeKeyboard, @"keyboard", nil);
  FBFocusSnapshotDouble *app = FBNode(XCUIElementTypeApplication, @"app",
                                      @[FBNode(XCUIElementTypeWindow, @"main", nil),
                                        FBNode(XCUIElementTypeWindow, @"sheetWindow", @[sheet]),
                                        keyboard]);

  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  NSDictionary *tree = FBWalk((id<FBXCElementSnapshot>)app, context);

  NSMutableArray<NSString *> *focused = [NSMutableArray array];
  FBCollectFocused(tree, focused);
  XCTAssertEqualObjects(focused, @[@"name"]);
  XCTAssertEqualObjects(context[@"focusedElement"][@"resourceId"], @"name");
  XCTAssertEqualObjects(context[@"focusedElement"][@"className"], @"XCUIElementTypeTextField");
  XCTAssertTrue([context[@"isEditable"] boolValue]);
  XCTAssertTrue([context[@"keyboardVisible"] boolValue]);
}

- (void)testDeepestKeyboardFocusWins
{
  // An ancestor reporting keyboard focus must not shadow the field that has it.
  FBFocusSnapshotDouble *field = FBNode(XCUIElementTypeSecureTextField, @"password", nil);
  field.fakeHasKeyboardFocus = YES;
  FBFocusSnapshotDouble *container = FBNode(XCUIElementTypeOther, @"container", @[field]);
  container.fakeHasKeyboardFocus = YES;
  FBFocusSnapshotDouble *app = FBNode(XCUIElementTypeApplication, @"app", @[container]);

  id<FBXCElementSnapshot> focused =
    [XCUIApplication fb_mobilerunFocusedSnapshotInTree:(id<FBXCElementSnapshot>)app];
  XCTAssertEqual((id)focused, (id)field);
}

- (void)testIsEditingTraitIsTheFallback
{
  FBFocusSnapshotDouble *plain = FBNode(XCUIElementTypeTextField, @"plain", nil);
  FBFocusSnapshotDouble *editing = FBNode(XCUIElementTypeOther, @"editing", nil);
  editing.fakeTraits = FBTestTraitIsEditing;
  FBFocusSnapshotDouble *app = FBNode(XCUIElementTypeApplication, @"app", @[plain, editing]);

  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  NSDictionary *tree = FBWalk((id<FBXCElementSnapshot>)app, context);

  NSMutableArray<NSString *> *focused = [NSMutableArray array];
  FBCollectFocused(tree, focused);
  XCTAssertEqualObjects(focused, @[@"editing"]);
  // Not a text input type, but the IsEditing trait says it takes text.
  XCTAssertTrue([context[@"isEditable"] boolValue]);
}

- (void)testKeyboardFocusOutranksIsEditingTrait
{
  FBFocusSnapshotDouble *editing = FBNode(XCUIElementTypeTextField, @"editing", nil);
  editing.fakeTraits = FBTestTraitIsEditing;
  FBFocusSnapshotDouble *keyboardFocused = FBNode(XCUIElementTypeTextView, @"keyboardFocused", nil);
  keyboardFocused.fakeHasKeyboardFocus = YES;
  FBFocusSnapshotDouble *app = FBNode(XCUIElementTypeApplication, @"app", @[editing, keyboardFocused]);

  id<FBXCElementSnapshot> focused =
    [XCUIApplication fb_mobilerunFocusedSnapshotInTree:(id<FBXCElementSnapshot>)app];
  XCTAssertEqual((id)focused, (id)keyboardFocused);
}

- (void)testNothingFocusedWithoutATree
{
  XCTAssertNil([XCUIApplication fb_mobilerunFocusedSnapshotInTree:nil]);
}

@end
