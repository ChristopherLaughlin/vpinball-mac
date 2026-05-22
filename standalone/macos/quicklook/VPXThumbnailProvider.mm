#import <Cocoa/Cocoa.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#include "pole/pole.h"
#include <vector>

@interface VPXThumbnailProvider : QLThumbnailProvider
@end

@implementation VPXThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest*)request
                     completionHandler:(void (^)(QLThumbnailReply* _Nullable, NSError* _Nullable))handler
{
   NSString* path = request.fileURL.path;
   NSImage* image = [self extractImageFromVPX:path];

   if (!image) {
      handler(nil, [NSError errorWithDomain:@"VPXQuickLook" code:1 userInfo:nil]);
      return;
   }

   CGSize maxSize = request.maximumSize;
   NSSize imageSize = image.size;
   CGFloat scale = MIN(maxSize.width / imageSize.width, maxSize.height / imageSize.height);
   CGSize drawSize = CGSizeMake(imageSize.width * scale, imageSize.height * scale);

   QLThumbnailReply* reply = [QLThumbnailReply replyWithContextSize:drawSize
      drawingBlock:^BOOL(CGContextRef ctx) {
         NSGraphicsContext* gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
         [NSGraphicsContext setCurrentContext:gc];
         [image drawInRect:NSMakeRect(0, 0, drawSize.width, drawSize.height)
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1.0];
         return YES;
      }];

   handler(reply, nil);
}

- (NSImage*)extractImageFromVPX:(NSString*)vpxPath
{
   POLE::Storage storage([vpxPath UTF8String]);
   if (!storage.open())
      return nil;

   // Try Screenshot stream first
   NSImage* image = [self imageFromStream:storage path:"/GameStg/Screenshot"];

   // Fall back to scanning embedded images
   for (int i = 0; !image && i < 5; i++) {
      char path[64];
      snprintf(path, sizeof(path), "/GameStg/Image%d", i);
      image = [self imageFromBIFF:storage path:path];
   }

   return image;
}

- (NSImage*)imageFromStream:(POLE::Storage&)storage path:(const std::string&)path
{
   POLE::Stream stream(&storage, path);
   if (stream.fail() || stream.size() == 0 || stream.size() > 10 * 1024 * 1024)
      return nil;

   std::vector<unsigned char> buf(stream.size());
   stream.read(buf.data(), stream.size());
   NSData* data = [NSData dataWithBytes:buf.data() length:buf.size()];
   return [[NSImage alloc] initWithData:data];
}

- (NSImage*)imageFromBIFF:(POLE::Storage&)storage path:(const std::string&)path
{
   POLE::Stream stream(&storage, path);
   if (stream.fail() || stream.size() < 16 || stream.size() > 50 * 1024 * 1024)
      return nil;

   std::vector<unsigned char> buf(stream.size());
   stream.read(buf.data(), stream.size());

   const unsigned char jpegMagic[] = {0xFF, 0xD8, 0xFF};
   const unsigned char pngMagic[] = {0x89, 0x50, 0x4E, 0x47};
   const unsigned char webpRiff[] = {0x52, 0x49, 0x46, 0x46};

   for (size_t i = 0; i + 12 < buf.size(); i++) {
      if (memcmp(&buf[i], jpegMagic, 3) == 0 ||
          memcmp(&buf[i], pngMagic, 4) == 0 ||
          (memcmp(&buf[i], webpRiff, 4) == 0 && memcmp(&buf[i+8], "WEBP", 4) == 0)) {
         NSData* data = [NSData dataWithBytes:&buf[i] length:buf.size() - i];
         NSImage* img = [[NSImage alloc] initWithData:data];
         if (img)
            return img;
      }
   }
   return nil;
}

@end
