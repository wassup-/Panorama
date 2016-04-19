@interface PanoramaSphere : NSObject

-(id)init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile;

-(void)render;

-(void)swapTexture:(NSString*)textureFile;
-(void)swapTextureWithImage:(UIImage*)image;

-(CGPoint)imagePixelFromVector:(GLKVector3)vector;

@end
