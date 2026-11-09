import Foundation

/// アプリがアクティブでなくなったせいで生成が失敗したかを判定する。
/// iOS は裏に回ったアプリの通信を止めるので、その失敗だけは戻ったときにやり直せるようにする。
public enum InterruptedGeneration {
    /// 通信が途中で切れた・打ち切られたことを示すエラーか。
    /// 401 や入力過多などの API エラーはやり直しても同じ結果になるので含めない。
    public static func isConnectionInterruption(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, interruptionCodes.contains(nsError.code) {
            return true
        }
        // ライブラリが URLError を包んで投げることがあるので、元のエラーもたどる。
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isConnectionInterruption(underlying)
        }
        return false
    }

    /// - Parameters:
    ///   - leftForegroundDuringGeneration: 生成中に一度でもアクティブでなくなったか
    ///   - failedInBackground: 失敗した時点でアクティブでなかったか
    ///   - alreadyRetried: すでに 1 回やり直した生成か
    public static func shouldRetry(
        error: Error,
        leftForegroundDuringGeneration: Bool,
        failedInBackground: Bool,
        alreadyRetried: Bool
    ) -> Bool {
        guard !alreadyRetried, leftForegroundDuringGeneration else { return false }
        // 裏で起きた失敗は原因を問わない。裏では接続が止められ、エラーの種類が当てにならないため。
        // 戻ってから届いた失敗は、裏で切られた接続の後始末なので通信断のときだけに絞る。
        return failedInBackground || isConnectionInterruption(error)
    }

    private static let interruptionCodes: Set<Int> = [
        URLError.networkConnectionLost.rawValue,
        URLError.cancelled.rawValue,
        URLError.timedOut.rawValue,
        URLError.notConnectedToInternet.rawValue,
        URLError.backgroundSessionWasDisconnected.rawValue,
    ]
}
