#import "FinderFavoritesBridge.h"
#import <CoreServices/CoreServices.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSURL *Resolve(LSSharedFileListItemRef item) {
    return CFBridgingRelease(LSSharedFileListItemCopyResolvedURL(item,
        kLSSharedFileListDoNotMountVolumes | kLSSharedFileListNoUserInteraction, NULL));
}
static void Failure(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:code userInfo:nil];
}
NSArray<NSDictionary *> *FEFinderFavorites(NSError **error) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
    if (!list) { Failure(error, -50); return nil; }
    NSArray *snapshot = CFBridgingRelease(LSSharedFileListCopySnapshot(list, NULL));
    if (!snapshot) { CFRelease(list); Failure(error, -50); return nil; }
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id raw in snapshot) {
        LSSharedFileListItemRef item = (__bridge LSSharedFileListItemRef)raw;
        NSURL *url = Resolve(item).URLByStandardizingPath;
        if (!url.isFileURL || [seen containsObject:url.path]) continue;
        NSNumber *directory = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory && !directory.boolValue) continue;
        [seen addObject:url.path];
        NSString *name = CFBridgingRelease(LSSharedFileListItemCopyDisplayName(item));
        [result addObject:@{@"url":url, @"name":name ?: @""}];
    }
    CFRelease(list);
    return result;
}
BOOL FEChangeFinderFavorite(NSURL *url, NSString *operation, NSURL *neighbor, NSError **error) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
    if (!list) { Failure(error, -50); return NO; }
    NSArray *snapshot = CFBridgingRelease(LSSharedFileListCopySnapshot(list, NULL));
    LSSharedFileListItemRef target = NULL, adjacent = NULL;
    for (id raw in snapshot) {
        LSSharedFileListItemRef item = (__bridge LSSharedFileListItemRef)raw;
        NSString *path = Resolve(item).URLByStandardizingPath.path;
        if ([path isEqualToString:url.URLByStandardizingPath.path]) target = item;
        if (neighbor && [path isEqualToString:neighbor.URLByStandardizingPath.path]) adjacent = item;
    }
    OSStatus status = noErr;
    if ([operation isEqualToString:@"add"]) {
        if (!target) {
            LSSharedFileListItemRef inserted = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast,
                NULL, NULL, (__bridge CFURLRef)url, NULL, NULL);
            if (inserted) CFRelease(inserted); else status = -50;
        }
    } else if ([operation isEqualToString:@"remove"]) {
        if (target) status = LSSharedFileListItemRemove(list, target);
    } else if (target && adjacent && target != adjacent) {
        LSSharedFileListItemRef after = adjacent;
        if ([operation isEqualToString:@"before"]) {
            after = kLSSharedFileListItemBeforeFirst;
            for (id raw in snapshot) {
                LSSharedFileListItemRef item = (__bridge LSSharedFileListItemRef)raw;
                if (item == adjacent) break;
                if (item != target) after = item;
            }
        }
        status = LSSharedFileListItemMove(list, target, after);
    } else status = -50;
    CFRelease(list);
    if (status) Failure(error, status);
    return status == noErr;
}
