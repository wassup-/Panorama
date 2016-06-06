/**
 * @class Panorama Sphere
 * @author Tom Knapen
 * @date 6/06/16
 *
 * @availability iOS (5.0 and later)
 *
 * @discussion
 */

@import Foundation;
@import GLKit;

@interface PanoramaSphere : NSObject

-(id)init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile;

-(void)render;

-(void)swapTexture:(NSString*)textureFile;
-(void)swapTextureWithImage:(UIImage*)image;

-(CGPoint)imagePixelFromVector:(GLKVector3)vector;

@end
