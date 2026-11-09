import XCTest
@testable import WhiplashCore

final class InterruptedGenerationTests: XCTestCase {
    private struct APIError: Error {}

    func test_接続断やタイムアウトや打ち切りは通信断とみなす() {
        XCTAssertTrue(InterruptedGeneration.isConnectionInterruption(URLError(.networkConnectionLost)))
        XCTAssertTrue(InterruptedGeneration.isConnectionInterruption(URLError(.cancelled)))
        XCTAssertTrue(InterruptedGeneration.isConnectionInterruption(URLError(.timedOut)))
        XCTAssertTrue(InterruptedGeneration.isConnectionInterruption(CancellationError()))
    }

    func test_通信断と関係ないエラーは通信断とみなさない() {
        XCTAssertFalse(InterruptedGeneration.isConnectionInterruption(URLError(.badServerResponse)))
        XCTAssertFalse(InterruptedGeneration.isConnectionInterruption(APIError()))
    }

    func test_別のエラーに包まれた接続断も通信断とみなす() {
        let wrapped = NSError(domain: "AnyLanguageModel", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        XCTAssertTrue(InterruptedGeneration.isConnectionInterruption(wrapped))
    }

    func test_裏に回っている間に失敗したらエラーの種類によらずやり直す() {
        XCTAssertTrue(InterruptedGeneration.shouldRetry(
            error: APIError(), leftForegroundDuringGeneration: true, failedInBackground: true, alreadyRetried: false))
    }

    func test_裏から戻った後に届いた接続断はやり直す() {
        XCTAssertTrue(InterruptedGeneration.shouldRetry(
            error: URLError(.networkConnectionLost), leftForegroundDuringGeneration: true, failedInBackground: false, alreadyRetried: false))
    }

    func test_裏から戻った後に届いた通信断以外のエラーはやり直さない() {
        XCTAssertFalse(InterruptedGeneration.shouldRetry(
            error: APIError(), leftForegroundDuringGeneration: true, failedInBackground: false, alreadyRetried: false))
    }

    func test_ずっと前面にいた間の接続断はやり直さずそのまま見せる() {
        XCTAssertFalse(InterruptedGeneration.shouldRetry(
            error: URLError(.networkConnectionLost), leftForegroundDuringGeneration: false, failedInBackground: false, alreadyRetried: false))
    }

    func test_やり直しは1回だけ() {
        XCTAssertFalse(InterruptedGeneration.shouldRetry(
            error: URLError(.networkConnectionLost), leftForegroundDuringGeneration: true, failedInBackground: true, alreadyRetried: true))
    }
}
