#import <Cocoa/Cocoa.h>
#import "MTAppDelegate.h"

static NSMenu *MTBuildMainMenu(void) {
    NSMenu *menuBar = [NSMenu new];

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Mac Typer" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Mac Typer"];
    [appMenu addItemWithTitle:@"显示主窗口" action:@selector(showMainWindow:) keyEquivalent:@"0"];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"隐藏 Mac Typer" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 Mac Typer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [menuBar addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"文件" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"导入文本…" action:@selector(importText:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"关闭窗口" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [menuBar addItem:fileItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:NSMenuItem.separatorItem];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [menuBar addItem:editItem];

    return menuBar;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        MTAppDelegate *delegate = [MTAppDelegate new];
        app.delegate = delegate;
        app.mainMenu = MTBuildMainMenu();
        [app run];
    }
    return 0;
}
