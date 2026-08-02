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
    @Query private var existingTags: [LocationTag]

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090), latitudinalMeters: 4000, longitudinalMeters: 4000)
    )
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var addressLabel = ""
    @State private var radiusMeters: Double = 400

    init(tagName: String) {
        self.tagName = tagName
        _existingTags = Query(filter: #Predicate<LocationTag> { $0.name == tagName })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $position) {
                        if let selectedCoordinate {
                            Marker(addressLabel.isEmpty ? tagName : addressLabel, coordinate: selectedCoordinate)
                        }
                    }
                    .onTapGesture { screenPoint in
                        guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                        selectedCoordinate = coordinate
                        addressLabel = ""
                        searchResults = []
                    }
                }
                .frame(height: 260)

                Form {
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

                    if selectedCoordinate != nil {
                        Section("Notify Within") {
                            Stepper(radiusDescription, value: $radiusMeters, in: 50...2000, step: 50)
                        }
                    }
                }
            }
            .navigationTitle("Tag Location: \(tagName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { save() }
                        .disabled(selectedCoordinate == nil)
                }
            }
            .onAppear {
                if let existing = existingTags.first {
                    selectedCoordinate = existing.coordinate
                    addressLabel = existing.addressLabel
                    radiusMeters = existing.radiusMeters
                    position = .region(MKCoordinateRegion(center: existing.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
                }
            }
        }
    }

    private var radiusDescription: String {
        let minutes = max(1, Int(radiusMeters / 80))
        return "\(Int(radiusMeters))m · ~\(minutes) min walk"
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
        guard let coordinate = selectedCoordinate else { return }
        if let existing = existingTags.first {
            existing.latitude = coordinate.latitude
            existing.longitude = coordinate.longitude
            existing.radiusMeters = radiusMeters
            existing.addressLabel = addressLabel
        } else {
            modelContext.insert(LocationTag(
                name: tagName,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: radiusMeters,
                addressLabel: addressLabel
            ))
        }
        dismiss()
    }
}

#Preview {
    LocationTagPickerView(tagName: "costco")
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, LocationTag.self], inMemory: true)
}
