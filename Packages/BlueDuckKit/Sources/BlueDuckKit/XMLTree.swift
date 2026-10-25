import Foundation

/// Parses small S3 XML responses into a lightweight element tree.
enum XMLTree {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []

        init(name: String) { self.name = name }

        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func children(_ name: String) -> [Node] { children.filter { $0.name == name } }
    }

    struct ParseError: Error {}

    static func parse(_ data: Data) throws -> Node {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw ParseError() }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = Node(name: elementName)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}
