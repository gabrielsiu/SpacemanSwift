import SwiftUI

struct ContentView: View {
    @State private var model = ComicViewModel()
    @State private var showingDatePicker = false
    @State private var zoom: CGFloat = 1
    @State private var swipeOffset: CGFloat = 0

    private var isZoomed: Bool { zoom > 1 }

    var body: some View {
        NavigationStack {
            comic
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .navigationTitle(model.date.formatted(date: .long, time: .omitted))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(isZoomed ? .hidden : .automatic, for: .navigationBar, .bottomBar)
                .statusBarHidden(isZoomed)
                .animation(.easeInOut(duration: 0.2), value: isZoomed)
                .overlay(alignment: .bottom) {
                    if isZoomed {
                        Button {
                            withAnimation(.snappy) { zoom = 1 }
                        } label: {
                            Label("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .padding(.bottom, 24)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Pick Date", systemImage: "calendar") { showingDatePicker = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Settings", systemImage: "gearshape") {
                            // Intentionally empty for now.
                            Button("No settings yet") {}.disabled(true)
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Previous Day", systemImage: "chevron.left") { model.step(by: -1) }
                            .disabled(!model.canGoBack)
                        Spacer()
                        Button("Today") { model.goToToday() }
                            .disabled(model.isToday)
                        Spacer()
                        Button("Next Day", systemImage: "chevron.right") { model.step(by: 1) }
                            .disabled(!model.canGoForward)
                    }
                }
        }
        .task(id: model.date) {
            zoom = 1
            await model.load()
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(model: model)
        }
    }

    @ViewBuilder
    private var comic: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Strip", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded(let url):
            ZoomableView(scale: $zoom, swipeOffset: $swipeOffset,
                         canSwipe: canSwipe, onSwipe: handleSwipe) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        ContentUnavailableView("Image Failed to Load", systemImage: "photo")
                    default:
                        ProgressView()
                    }
                }
            }
            .id(url) // reset zoom for each new strip
            .onAppear {
                // After a committed swipe the new strip starts off-screen; slide it in.
                if swipeOffset != 0 { withAnimation(.snappy) { swipeOffset = 0 } }
            }
        }
    }

    // Swipe right = reveal the previous (older) day, like turning a page back.
    private func canSwipe(_ direction: SwipeDirection) -> Bool {
        direction == .right ? model.canGoBack : model.canGoForward
    }

    private func handleSwipe(_ direction: SwipeDirection) {
        // The old strip is fully off-screen; park the next one on the opposite side
        // so it slides in once loaded (see onAppear above).
        swipeOffset = direction == .right ? -screenWidth : screenWidth
        model.step(by: direction == .right ? -1 : 1)
    }

    private var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }.first ?? 400
    }
}

private struct DatePickerSheet: View {
    var model: ComicViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(model: ComicViewModel) {
        self.model = model
        _selection = State(initialValue: model.date)
    }

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $selection,
                       in: model.earliest...model.today, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Go to Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") { model.select(selection); dismiss() }
                    }
                }
            Spacer()
        }
        .presentationDetents([.medium, .large])
    }
}
