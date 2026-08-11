import SwiftUI
import MapKit
import SwiftData

/// Create a brand-new entry in the tag box, optionally attaching a
/// real-world location up front. `onSave` hands back the saved tag's
/// canonical name so a caller (e.g. a task's tag field) can attach it.
struct NewTagSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var existingTags: [Tag]

    @State private var name: String
    @State private var isAddingLocation = false
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090), latitudinalMeters: 4000, longitudinalMeters: 4000)
    )
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var addressLabel = ""
    @State private var radiusMiles: Double = 0.5
    @State private var notifyWhenNear = true
    @State private var errorMessage: String?

    let onSave: (String) -> Void

    init(prefilledName: String = "", onSave: @escaping (String) -> Void) {
        _name = State(initialValue: prefilledName)
        self.onSave = onSave
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

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Name a tag first."
            return
        }

        let hasLocation = isAddingLocation && selectedCoordinate != nil

        // Matched case-insensitively (typing "dt groton" should still
        // land on an existing "DT Groton" rather than fork a near-
        // duplicate), but a genuinely new tag keeps the exact case typed
        // here — see the `else` branch below.
        if let existing = existingTags.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            if hasLocation, let coordinate = selectedCoordinate {
                existing.hasLocation = true
                existing.latitude = coordinate.latitude
                existing.longitude = coordinate.longitude
                existing.radiusMeters = radiusMiles * Tag.metersPerMile
                existing.addressLabel = addressLabel
                existing.notifyWhenNear = notifyWhenNear
            }
            onSave(existing.name)
        } else {
            let tag: Tag
            if hasLocation, let coordinate = selectedCoordinate {
                tag = Tag(name: trimmed, hasLocation: true, latitude: coordinate.latitude, longitude: coordinate.longitude, radiusMeters: radiusMiles * Tag.metersPerMile, addressLabel: addressLabel, notifyWhenNear: notifyWhenNear)
            } else {
                tag = Tag(name: trimmed)
            }
            modelContext.insert(tag)
            onSave(tag.name)
        }
        dismiss()
    }
}

#Preview {
    NewTagSheet { _ in }
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
