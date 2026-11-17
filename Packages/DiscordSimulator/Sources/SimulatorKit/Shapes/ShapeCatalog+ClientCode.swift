import Foundation

/// Response fields no capture has seen, taken from the official client's code instead. They are
/// added after the captured fields and never change those; DESIGN.md lists each.
extension ShapeCatalog {
    /// The personal widget (Nitro-only, never captured), as the client's widget parser reads it:
    /// `header`, then `sections` of type `cover` (`title`, `subtitle`, `image`) or `fields` (each a
    /// `title`, `description` and `image`). A saved image is `file_id`, `width`, `height`, `is_animated`.
    private static let personalWidget = """
    {"t": "object", "f": {"widgets": {"t": "array", "i": {"t": "object", "f": {"data": {"t": "object", "f": {
      "header": {"t": "string", "opt": true},
      "sections": {"t": "array", "opt": true, "i": {"t": "object", "f": {
        "type": {"t": "string"}, "title": {"t": "string", "opt": true}, "subtitle": {"t": "string", "opt": true},
        "image": {"t": "object", "opt": true, "f": {
          "file_id": {"t": "string"}, "width": {"t": "int"}, "height": {"t": "int"}, "is_animated": {"t": "bool"}}},
        "fields": {"t": "array", "opt": true, "i": {"t": "object", "f": {
          "title": {"t": "string"}, "description": {"t": "string"},
          "image": {"t": "object", "opt": true, "f": {
            "file_id": {"t": "string"}, "width": {"t": "int"}, "height": {"t": "int"}, "is_animated": {"t": "bool"}}}}}}}}}}}}}}}}
    """

    mutating func addClientCodeShapes() throws {
        let widgets = try ShapeNode(encoded: JSON.parse(Data(Self.personalWidget.utf8)))
        for route in ["PUT /api/v9/users/@me/widgets", "GET /api/v9/users/{id}/profile"] {
            routes[route]?.responses[200]?.supplement(with: widgets)
        }
    }
}

private extension ShapeNode {
    /// Adds the fields of `extra` this shape lacks, after its own and at any depth.
    mutating func supplement(with extra: ShapeNode) {
        for field in extra.fields {
            if let index = fields.firstIndex(where: { $0.name == field.name }) {
                fields[index].node.supplement(with: field.node)
            } else {
                fields.append(field)
            }
        }
        if let extraItems = extra.items, var node = items?.value {
            node.supplement(with: extraItems.value)
            items = Box(node)
        }
    }
}
