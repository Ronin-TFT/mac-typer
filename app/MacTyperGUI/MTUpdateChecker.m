#import "MTUpdateChecker.h"

static NSString *const MTLatestReleaseAPI = @"https://api.github.com/repos/Ronin-TFT/mac-typer/releases/latest";

static NSString *MTStripVersionPrefix(NSString *version) {
    NSString *trimmed = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"]) trimmed = [trimmed substringFromIndex:1];
    return trimmed;
}

NSComparisonResult MTCompareVersions(NSString *a, NSString *b) {
    NSArray<NSString *> *left = [MTStripVersionPrefix(a) componentsSeparatedByString:@"."];
    NSArray<NSString *> *right = [MTStripVersionPrefix(b) componentsSeparatedByString:@"."];
    NSUInteger count = MAX(left.count, right.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger l = i < left.count ? left[i].integerValue : 0;
        NSInteger r = i < right.count ? right[i].integerValue : 0;
        if (l < r) return NSOrderedAscending;
        if (l > r) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSError *MTUpdateError(NSString *message) {
    return [NSError errorWithDomain:@"MacTyper.Update" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation MTUpdateChecker

+ (void)fetchLatestWithCompletion:(void (^)(NSString *, NSURL *, NSError *))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:MTLatestReleaseAPI]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"MacTyper" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *latest = nil;
        NSURL *url = nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && status != 200) error = MTUpdateError([NSString stringWithFormat:@"GitHub 返回 %ld", (long)status]);
        if (!error) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            NSString *tag = [json isKindOfClass:NSDictionary.class] ? json[@"tag_name"] : nil;
            NSString *page = [json isKindOfClass:NSDictionary.class] ? json[@"html_url"] : nil;
            if ([tag isKindOfClass:NSString.class] && [page isKindOfClass:NSString.class] &&
                [page hasPrefix:@"https://github.com/Ronin-TFT/mac-typer/"]) {
                latest = MTStripVersionPrefix(tag);
                url = [NSURL URLWithString:page];
            } else if (!error) {
                error = MTUpdateError(@"无法识别的版本信息");
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(latest, url, error); });
    }];
    [task resume];
}

@end
