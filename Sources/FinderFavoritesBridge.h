#import <Foundation/Foundation.h>
NSArray<NSDictionary *> *FEFinderFavorites(NSError **error);
BOOL FEChangeFinderFavorite(NSURL *url, NSString *operation, NSURL *neighbor, NSError **error);
