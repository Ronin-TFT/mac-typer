#import "MTUtil.h"
#import <math.h>

static const NSUInteger MTMaxTextFileBytes = 10 * 1024 * 1024;

static NSError *MTError(NSString *message) {
    return [NSError errorWithDomain:@"MacTyper" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL MTParseNumber(NSString *string, double max, BOOL integer, double *value) {
    NSScanner *scanner = [NSScanner scannerWithString:string ?: @""];
    double parsed = 0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed) || parsed < 0 || parsed > max) return NO;
    if (integer && floor(parsed) != parsed) return NO;
    if (value) *value = parsed;
    return YES;
}

NSString *MTDurationText(NSTimeInterval seconds) {
    long total = lround(MAX(0, seconds));
    if (total >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

NSString *MTProgressText(NSInteger done, NSInteger total, NSTimeInterval activeSeconds) {
    NSString *base = [NSString stringWithFormat:@"已输入 %ld/%ld", (long)done, (long)total];
    if (done < 5 || done >= total || activeSeconds <= 0) return base;
    NSTimeInterval remaining = activeSeconds / done * (total - done);
    return [base stringByAppendingFormat:@" · 约剩 %@", MTDurationText(remaining)];
}

NSString *MTReadTextFile(NSURL *url, NSError **error) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    if (data.length > MTMaxTextFileBytes) {
        if (error) *error = MTError(@"文件超过 10 MB，无法导入");
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    NSString *text = nil;
    if (data.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    } else if (memchr(bytes, 0, data.length) == NULL) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {
            NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
            text = [[NSString alloc] initWithData:data encoding:gb];
        }
    }
    if (!text) {
        if (error) *error = MTError(@"不是可识别的纯文本文件（支持 UTF-8、UTF-16、GB18030）");
        return nil;
    }
    if ([text hasPrefix:@"﻿"]) text = [text substringFromIndex:1];
    return text;
}
