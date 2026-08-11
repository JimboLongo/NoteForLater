import SwiftUI
import MapKit
import SwiftData

/// Pick (or move) the real-world place a tag points to: search for it or
/// tap the map, adjust the notification radius, save. Any task/inbox item
/// carrying this tag becomes part of the proximity reminder for this spot.
struct LocationTagPickerView: View {
    let tagName: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var existingTags: [Tag]
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @Query private var allTagLinks: [TagLink]

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090), latitudinalMeters: 4000, longitudinalMeters: 4000)
    )
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var addressLabel = ""
    @State private var radiusMiles: Double = 0.5
    @State private var notifyWhenNear = true
    /// Editable copy of the tag's name — `tagName` itself stays fixed for
    /// the view's lifetime (it's what `existingTags` keeps querying by),
    /// so a rename here doesn't lose track of which tag is being edited
    /// until it's actually saved.
    @State private var name: String
    @State private var errorMessage: String?
    @State private var linkedTagSearchText = ""
    /// Same gate `NewTagSheet` uses — starts on only if this tag already
    /// has a saved location, so the map doesn't vanish on an existing
    /// location out from under you, but otherwise matches the new-tag
    /// experience of a plain toggle instead of an always-visible map.
    @State private var isAddingLocation = false

    init(tagName: String) {
        self.tagName = tagName
        _existingTags = Query(filter: #Predicate<Tag> { $0.name == tagName })
        _name = State(initialValue: tagName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tag") {
                    TextField("Tag name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Toggle("Attach a location", isOn: $isAddingLocation.animation())
                } footer: {
                    Text("You'll get a notification listing tagged tasks whenever you come within range.")
                }

                if isAddingLocation {
                    Section("Search") {
                        TextField("Search for a place", text: $searchText)
                            .onSubmit(search)
                        ForEach(searchResults, id: \.self) { item in
                            Button {
                                select(item)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Unknown place")
                                    if let address = item.placemark.title {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    MapReader { proxy in
                        Map(position: $position) {
                            if let selectedCoordinate {
                                Marker(addressLabel.isEmpty ? name : addressLabel, coordinate: selectedCoordinate)
                            }
                        }
                        .onTapGesture { screenPoint in
                            guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                            selectedCoordinate = coordinate
                            addressLabel = ""
                            searchResults = []
                        }
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())

                    if selectedCoordinate != nil {
                        Section {
                            Toggle("Notify Me When Near", isOn: $notifyWhenNear.animation())
                            if notifyWhenNear {
                                Stepper(radiusDescription, value: $radiusMiles, in: 0.5...5, step: 0.5)
                            }
                        }
                    }
                }

                if existingTags.first?.hasLocation == true {
                    Section {
                        Button("Remove Location", role: .destructive, action: removeLocation)
                    }
                }

                if existingTags.first != nil {
                    Section {
                        ForEach(linkedTagRows) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.otherTag.name)
                                Picker("", selection: Binding(
                                    get: { row.link.isTwoWay },
                                    set: { row.link.isTwoWay = $0 }
                                )) {
                                    Text("1-Way").tag(false)
                                    Text("2-Way").tag(true)
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete(perform: deleteLinks)

                        TextField("Link to another tag", text: $linkedTagSearchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        ForEach(linkableTagSuggestions) { suggestion in
                            Button(suggestion.name) {
                                addLink(to: suggestion)
                            }
                        }
                    } header: {
                        Text("Linked Tags")
                    } footer: {
                        Text("1-Way: searching the linked tag also finds this tag's items, but not the other way around. 2-Way: searching either tag finds both — and this link then shows up on the linked tag's own screen too. Search only; proximity notifications still key off this tag alone.")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reviewed", action: markReviewed)
                }
            }
            .onAppear {
                if let existing = existingTags.first, existing.hasLocation {
                    selectedCoordinate = existing.coordinate
                    addressLabel = existing.addressLabel
                    radiusMiles = existing.radiusMeters / Tag.metersPerMile
                    notifyWhenNear = existing.notifyWhenNear
                    position = .region(MKCoordinateRegion(center: existing.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
                    isAddingLocation = true
                }
            }
        }
    }

    private var radiusDescription: String {
        let minutes = max(1, Int((radiusMiles / Tag.averageDrivingMph * 60).rounded()))
        return String(format: "%.1f mi · ~%d min drive", radiusMiles, minutes)
    }

    private func search() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        if let coordinate = selectedCoordinate {
            request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 20000, longitudinalMeters: 20000)
        }
        Task {
            let search = MKLocalSearch(request: request)
            let response = try? await search.start()
            searchResults = response?.mapItems ?? []
        }
    }

    private func select(_ item: MKMapItem) {
        selectedCoordinate = item.placemark.coordinate
        addressLabel = item.name ?? ""
        position = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
        searchResults = []
        searchText = item.name ?? ""
    }

    /// The tag screen's one primary action — saves whatever location (if
    /// any) is currently selected, applies a rename if the Name field was
    /// changed (see `renameEverywhere`), and always marks the tag
    /// reviewed, so a tag that genuinely doesn't need a place attached
    /// can still be dismissed as "done" rather than being forced through
    /// Save first.
    private func markReviewed() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? tagName : trimmed

        // A different tag already claiming this name would leave two Tag
        // rows fighting over the same task/inbox-item tag strings — bail
        // out rather than silently corrupting that association.
        if finalName != tagName,
           (try? modelContext.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.name == finalName })))?.first != nil {
            errorMessage = "Another tag is already named \"\(finalName)\"."
            return
        }
        errorMessage = nil

        if let existing = existingTags.first {
            if finalName != tagName {
                existing.name = finalName
                renameEverywhere(from: tagName, to: finalName)
            }
            if isAddingLocation, let coordinate = selectedCoordinate {
                existing.hasLocation = true
                existing.latitude = coordinate.latitude
                existing.longitude = coordinate.longitude
                existing.radiusMeters = radiusMiles * Tag.metersPerMile
                existing.addressLabel = addressLabel
                existing.notifyWhenNear = notifyWhenNear
            }
            existing.isReviewed = true
        } else {
            if finalName != tagName {
                renameEverywhere(from: tagName, to: finalName)
            }
            let tag: Tag
            if isAddingLocation, let coordinate = selectedCoordinate {
                tag = Tag(
                    name: finalName,
                    hasLocation: true,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    radiusMeters: radiusMiles * Tag.metersPerMile,
                    addressLabel: addressLabel,
                    notifyWhenNear: notifyWhenNear
                )
            } else {
                tag = Tag(name: finalName)
            }
            tag.isReviewed = true
            modelContext.insert(tag)
        }
        dismiss()
    }

    /// `TaskItem.tags`/`InboxItem.tags` are plain string arrays, not a
    /// relationship to `Tag` — renaming the tag itself would otherwise
    /// silently orphan every task/inbox item that carried the old name.
    private func renameEverywhere(from oldName: String, to newName: String) {
        if let tasks = try? modelContext.fetch(FetchDescriptor<TaskItem>()) {
            for task in tasks where task.tags.contains(oldName) {
                task.tags = task.tags.map { $0 == oldName ? newName : $0 }
            }
        }
        if let items = try? modelContext.fetch(FetchDescriptor<InboxItem>()) {
            for item in items where item.tags.contains(oldName) {
                item.tags = item.tags.map { $0 == oldName ? newName : $0 }
            }
        }
    }

    private func removeLocation() {
        if let existing = existingTags.first {
            existing.hasLocation = false
        }
        dismiss()
    }

    /// One row per link this tag actually participates in — as the side
    /// it was originally added from, or (only once flipped 2-way) as the
    /// reciprocal side too. Both cases edit the exact same underlying
    /// `TagLink`, so toggling 1-Way/2-Way here and on the other tag's own
    /// screen stay in perfect sync.
    private struct LinkedTagRow: Identifiable {
        let link: TagLink
        let otherTag: Tag
        var id: UUID { link.id }
    }

    private var linkedTagRows: [LinkedTagRow] {
        guard let currentTag = existingTags.first else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
        var rows: [LinkedTagRow] = []
        for link in allTagLinks {
            if link.sourceTagID == currentTag.id, let other = byID[link.targetTagID] {
                rows.append(LinkedTagRow(link: link, otherTag: other))
            } else if link.targetTagID == currentTag.id, link.isTwoWay, let other = byID[link.sourceTagID] {
                rows.append(LinkedTagRow(link: link, otherTag: other))
            }
        }
        return rows.sorted { $0.otherTag.name < $1.otherTag.name }
    }

    private var linkableTagSuggestions: [Tag] {
        guard let currentTag = existingTags.first else { return [] }
        let trimmed = linkedTagSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let alreadyLinkedIDs = Set(linkedTagRows.map { $0.otherTag.id })
        return allTags.filter {
            $0.id != currentTag.id
                && !alreadyLinkedIDs.contains($0.id)
                && $0.name.lowercased().contains(trimmed)
        }
    }

    /// If the reverse direction already exists (this other tag was linked
    /// to this one first), flips that link two-way instead of inserting a
    /// redundant parallel one — either side adding the other now means
    /// the same thing.
    private func addLink(to targetTag: Tag) {
        guard let currentTag = existingTags.first else { return }
        if let reverse = allTagLinks.first(where: { $0.sourceTagID == targetTag.id && $0.targetTagID == currentTag.id }) {
            reverse.isTwoWay = true
        } else {
            modelContext.insert(TagLink(sourceTagID: currentTag.id, targetTagID: targetTag.id))
        }
        linkedTagSearchText = ""
    }

    private func deleteLinks(at offsets: IndexSet) {
        let rows = linkedTagRows
        for index in offsets {
            modelContext.delete(rows[index].link)
        }
    }
}

#Preview {
    LocationTagPickerView(tagName: "costco")
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, TagLink.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
