import Foundation

struct DonationConfig: Decodable {
    let usdt_trc20: String
    let usdt_polygon: String
    let btc: String
//     let donation_page: String?

    /// Inert placeholder shown when `donations.json` is missing or
    /// malformed. The About pane handles empty strings gracefully —
    /// crashing the app over a side-feature is never the right call.
    static let empty = DonationConfig(usdt_trc20: "", usdt_polygon: "", btc: "")
}

final class DonationService {
    static let shared = DonationService()

    private(set) var config: DonationConfig

    private init() {
        guard let url = Bundle.main.url(forResource: "donations", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            FileLogger.shared.warning(.app, "donations.json not found in bundle — using empty donation config")
            self.config = .empty
            return
        }
        do {
            self.config = try JSONDecoder().decode(DonationConfig.self, from: data)
        } catch {
            FileLogger.shared.warning(.app,
                "donations.json failed to decode (\(error.localizedDescription)) — using empty donation config")
            self.config = .empty
        }
    }
}