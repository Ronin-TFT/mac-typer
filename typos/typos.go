// Package typos 内置常用错词库。
package typos

import _ "embed"

// Common 是内置常用错词库（常见英文拼写错误与中文错别字），格式同错词库文件。
//
//go:embed common.txt
var Common string
