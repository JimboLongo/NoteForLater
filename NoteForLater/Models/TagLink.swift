import Foundation
import SwiftData

/// A directional relationship between two tags, used only to widen what
/// `InboxView`'s live search treats as a match — proximity notifications
/// (`LocationMonitoringService`) stay keyed to a task's literal tags and
/// never consult this at all.
///
/// `sourceTagID` is whichever tag the link was added *from* (its own
/// "Linked Tags" section is where `Tag.name`/`targetTagID` first got
/// typed in); `targetTagID` is the tag that was picked. Searching the
/// target always also surfaces anything tagged with the source — that's
/// the one-way behavior. Flipping `isTwoWay` on adds the reverse:
/// searching the source then also surfaces the target's own tagged items,
/// and the link starts showing up on the target's own Linked Tags section
/// too (both sides edit the same row from then on — see
/// `LocationTagPickerView`). Flipping it back off removes it from the
/// target's section again without deleting the link itself, since the
/// original one-way direction (source was added from) still holds.
@Model
final class TagLink {
    var id: UUID
    var sourceTagID: UUID
    var targetTagID: UUID
    var isTwoWay: Bool

    init(sourceTagID: UUID, targetTagID: UUID, isTwoWay: Bool = false) {
        self.id = UUID()
        self.sourceTagID = sourceTagID
        self.targetTagID = targetTagID
        self.isTwoWay = isTwoWay
    }

    /// Every tag name a search for `tag` should also treat as a match,
    /// including `tag`'s own name. Built once per search keystroke in
    /// `InboxView` — cheap enough given how few links/tags a personal
    /// tag list realistically holds.
    static func expandedSearchTagNames(for tag: Tag, allTags: [Tag], allLinks: [TagLink]) -> Set<String> {
        var names: Set<String> = [tag.name]
        let byID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
        for link in allLinks {
            if link.targetTagID == tag.id, let source = byID[link.sourceTagID] {
                names.insert(source.name)
            }
            if link.sourceTagID == tag.id, link.isTwoWay, let target = byID[link.targetTagID] {
                names.insert(target.name)
            }
        }
        return names
    }
}
