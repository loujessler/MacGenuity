import Foundation

struct DonationConfig: Decodable {
    let usdt_trc20: String
    let usdt_polygon: String
    let btc: String
//     let donation_page: String?
}

final class DonationService {
    static let shared = DonationService()

    private(set) var config: DonationConfig

    private init() {
        guard let url = Bundle.main.url(forResource: "donations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DonationConfig.self, from: data)
        else {
            fatalError("Failed to load donations.json")
        }

        self.config = decoded
    }
}