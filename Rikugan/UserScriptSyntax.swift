import Foundation
import JavaScriptCore

enum UserScriptSyntax {
    /// Parse a function body without executing the supplied script or its dependencies.
    static func validate(_ source: String) throws {
        guard let context = JSContext() else { throw RikuganError.message("不能创建脚本语法检查环境。") }
        let data = try JSONSerialization.data(withJSONObject: [source])
        guard let literal = String(data: data, encoding: .utf8) else { throw RikuganError.message("脚本不是有效 UTF-8 文本。") }
        context.evaluateScript("new Function(\(literal)[0]);")
        if let exception = context.exception {
            throw RikuganError.message("JavaScript 语法错误：\(exception.toString() ?? "未知错误")")
        }
    }
}
