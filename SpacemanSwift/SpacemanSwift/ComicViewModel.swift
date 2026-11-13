import Foundation
import Observation

@Observable
final class ComicViewModel {
    enum State {
        case loading
        case loaded(URL)
        case failed(String)
    }

    private(set) var state: State = .loading
    var date: Date = Calendar.current.startOfDay(for: .now)

    private let service = ComicService()

    var today: Date { Calendar.current.startOfDay(for: .now) }
    var earliest: Date { ComicService.firstStripDate }
    var canGoBack: Bool { date > earliest }
    var canGoForward: Bool { date < today }
    var isToday: Bool { Calendar.current.isDate(date, inSameDayAs: today) }

    func load() async {
        state = .loading
        do {
            let url = try await service.imageURL(for: date)
            state = .loaded(url)
        } catch is CancellationError {
            // A newer load replaced this one; leave state to it.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func step(by days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        select(next)
    }

    func select(_ newDate: Date) {
        let day = Calendar.current.startOfDay(for: newDate)
        date = min(max(day, earliest), today)
    }

    func goToToday() { select(today) }
}
