#import "MTDropTextView.h"
#import "MTUtil.h"

@implementation MTDropTextView

- (NSArray<NSPasteboardType> *)acceptableDragTypes {
    NSArray<NSPasteboardType> *types = [super acceptableDragTypes] ?: @[];
    return [types containsObject:NSPasteboardTypeFileURL] ? types : [types arrayByAddingObject:NSPasteboardTypeFileURL];
}

- (nullable NSURL *)fileURLFromDrag:(id<NSDraggingInfo>)info {
    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                                    options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    return urls.firstObject;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self fileURLFromDrag:sender] ? NSDragOperationCopy : [super draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self fileURLFromDrag:sender] ? NSDragOperationCopy : [super draggingUpdated:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSURL *url = [self fileURLFromDrag:sender];
    if (!url) return [super performDragOperation:sender];
    NSError *error = nil;
    NSString *text = MTReadTextFile(url, &error);
    if (text) [self replaceAllText:text];
    if (self.importHandler) self.importHandler(url, text ? nil : error);
    return text != nil;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    if ([self fileURLFromDrag:sender]) return;
    [super concludeDragOperation:sender];
}

- (void)replaceAllText:(NSString *)text {
    NSRange all = NSMakeRange(0, self.string.length);
    if ([self shouldChangeTextInRange:all replacementString:text]) {
        [self replaceCharactersInRange:all withString:text];
        [self didChangeText];
    }
    [self setSelectedRange:NSMakeRange(0, 0)];
    [self scrollRangeToVisible:NSMakeRange(0, 0)];
}

@end
