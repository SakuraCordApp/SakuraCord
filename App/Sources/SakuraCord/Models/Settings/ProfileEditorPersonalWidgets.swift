import SakuraCordModels

/// Where a personal widget image sits. Field IDs are regenerated when the
/// profile reloads, so upload state is keyed by position instead.
struct ProfileWidgetImageSlot: Hashable {
    let widgetID: String
    var section: Int
    /// The field's position in its section; nil for the cover.
    var position: Int?
}

extension ProfileEditorState {
    func updatePersonalWidget(id: String, _ update: (inout ProfilePersonalWidget) -> Void) {
        guard canEditPersonalWidget, var widget = widgets.first(where: { $0.id == id }), case var .personal(personal) = widget.content else { return }
        update(&personal)
        widget.content = .personal(personal)
        updateWidget(widget)
    }

    func updateWidgetCover(id: String, section: Int, _ update: (inout ProfileWidgetCover) -> Void) {
        updatePersonalWidget(id: id) { personal in
            guard personal.sections.indices.contains(section), case var .cover(cover) = personal.sections[section] else { return }
            update(&cover); personal.sections[section] = .cover(cover)
        }
    }

    func updateWidgetField(id: String, section: Int, fieldID: ProfileWidgetField.ID, _ update: (inout ProfileWidgetField) -> Void) {
        updatePersonalWidget(id: id) { personal in
            guard personal.sections.indices.contains(section), case var .fields(fields) = personal.sections[section],
                  let index = fields.firstIndex(where: { $0.id == fieldID }) else { return }
            update(&fields[index]); personal.sections[section] = .fields(fields)
        }
    }

    func removeWidgetField(id: String, section: Int, fieldID: ProfileWidgetField.ID) {
        updatePersonalWidget(id: id) { personal in
            guard personal.sections.indices.contains(section), case var .fields(fields) = personal.sections[section],
                  let removed = fields.firstIndex(where: { $0.id == fieldID }) else { return }
            fields.remove(at: removed)
            personal.sections[section] = .fields(fields)
            remapWidgetImageFailures(in: id) { slot in
                guard slot.section == section, let position = slot.position, position >= removed else { return slot }
                return position == removed ? nil : ProfileWidgetImageSlot(widgetID: id, section: section, position: position - 1)
            }
        }
    }

    func insertWidgetCover(id: String) {
        updatePersonalWidget(id: id) { personal in
            personal.sections.insert(.cover(ProfileWidgetCover()), at: 0)
            remapWidgetImageFailures(in: id) { ProfileWidgetImageSlot(widgetID: id, section: $0.section + 1, position: $0.position) }
        }
    }

    func removeWidgetCover(id: String, section: Int) {
        updatePersonalWidget(id: id) { personal in
            guard personal.sections.indices.contains(section), case .cover = personal.sections[section] else { return }
            personal.sections.remove(at: section)
            remapWidgetImageFailures(in: id) { slot in
                slot.section == section ? nil : ProfileWidgetImageSlot(widgetID: id, section: slot.section - (slot.section > section ? 1 : 0), position: slot.position)
            }
        }
    }

    func addWidgetFields(id: String, section: Int, count: Int) {
        updatePersonalWidget(id: id) { personal in
            guard personal.sections.indices.contains(section), case var .fields(fields) = personal.sections[section],
                  count > 0, fields.count + count <= 4 else { return }
            fields.append(contentsOf: (0 ..< count).map { _ in ProfileWidgetField() })
            personal.sections[section] = .fields(fields)
        }
    }
}
