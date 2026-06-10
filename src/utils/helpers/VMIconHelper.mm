#import "include/VMIconHelper.h"
@implementation VMIconHelper
+ (UIImage *)compatibleSystemImageNamed:(NSString *)name {
    UIImage *image = [UIImage systemImageNamed:name];
    if (image) return image;
    
    NSString *fallbackName = [self fallbackNameFor:name];
    if (fallbackName) {
        image = [UIImage systemImageNamed:fallbackName];
    }
    
    return image ?: [UIImage systemImageNamed:@"square.grid.2x2"]; 
}

+ (NSString *)fallbackNameFor:(NSString *)name {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"list.bullet.rectangle": @"list.bullet",       
            @"line.3.horizontal.decrease.circle": @"line.horizontal.3.decrease.circle", 
            @"line.3.horizontal.decrease.circle.fill": @"line.horizontal.3.decrease.circle.fill",
            @"arrow.turn.down.right": @"arrow.turn.right.down", 
            @"chevron.backward": @"chevron.left",           
            
            @"folder.badge.gearshape": @"folder.badge.gear", 
            @"folder.fill": @"folder",
            
            @"arrow.counterclockwise": @"arrow.uturn.left",
            @"arrow.triangle.2.circlepath": @"arrow.2.circlepath", 
            @"clock.arrow.circlepath": @"clock",
            @"cpu": @"memorychip",
            @"hammer": @"wrench",
            @"list.bullet.clipboard": @"doc.text",
            @"checklist": @"checkmark.circle",
            
            @"square.and.arrow.up": @"square.and.arrow.up", 
            @"square.and.arrow.down": @"square.and.arrow.down",
            
            @"checkmark.shield.fill": @"lock.shield.fill",
            @"exclamationmark.triangle": @"exclamationmark",
            
            @"link": @"link",
            @"link.badge.plus": @"link",
        };
    });
    
    return map[name];
}

+ (UIImage *)compatibleSystemImageNamed:(NSString *)name fallback:(NSString *)fallbackName {
    UIImage *image = [UIImage systemImageNamed:name];
    
    if (!image) {
        image = [UIImage systemImageNamed:fallbackName];
    }
    
    return image;
}

+ (UIImage *)fallbackImageForName:(NSString *)name {
    NSString *fallbackName = [self fallbackNameFor:name];
    if (fallbackName) {
        return [UIImage systemImageNamed:fallbackName];
    }
    
    return nil;
}

@end
