import Foundation
import Darwin
import SSH2

/// Small libssh2 wrapper. NMSSH's CFSocket connection path does not work
/// reliably on current iOS releases, so this uses a normal BSD socket and
/// libssh2 directly. Every operation runs on the same private queue.
final class SSHService {
    private let queue = DispatchQueue(label: "com.catmint.openwrtmonitor.ssh")
    private var session: OpaquePointer?
    private var socketFD: Int32 = -1

    // 取消标记必须能在连接过程中被外部读到，所以用锁保护、不跟 queue 绑在一起：
    // 连接时 queue 是被占住的，投进来的 block 排队执行等于永远轮不到。
    private let stateLock = NSLock()
    private var cancelledFlag = false
    private var pendingFD: Int32 = -1

    /// 主动中止正在进行的连接。
    ///
    /// 置取消标记让阻塞点自己退出，同时 shutdown 掉正在握手的 socket，
    /// 这样卡在 `connect()`/`libssh2_session_handshake` 里也能立刻返回。
    func cancelAttempt() {
        stateLock.lock()
        cancelledFlag = true
        let fd = pendingFD
        stateLock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledFlag
    }

    private func setPendingFD(_ fd: Int32) {
        stateLock.lock()
        pendingFD = fd
        stateLock.unlock()
    }

    func connect(host: String, port: Int, user: String, password: String,
                 timeout: TimeInterval = 8) async throws {
        // 取消标记在派发之前就清掉：万一用户点「停止」比队列排到还早，
        // 清标记不能把它一起抹掉（放在队列 block 里就有这个时间窗）。
        stateLock.lock()
        cancelledFlag = false
        pendingFD = -1
        stateLock.unlock()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.closeLocked()
                libssh2_init(0)

                do {
                    try self.handshakeLocked(host: host, port: port, user: user,
                                             password: password, timeout: timeout)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 建 socket → 握手 → 认证。整个过程都是可中止的。
    private func handshakeLocked(host: String, port: Int, user: String,
                                 password: String, timeout: TimeInterval) throws {
        let fd = try openSocket(host: host, port: port, timeout: timeout)
        var adopted = false
        defer {
            setPendingFD(-1)
            if !adopted { Darwin.close(fd) }
        }

        guard let ssh = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw AppError.message("libssh2 初始化失败")
        }
        var sessionFreed = false
        defer { if !sessionFreed { libssh2_session_free(ssh) } }
        libssh2_session_set_blocking(ssh, 1)

        if isCancelled { throw AppError.cancelled }
        guard libssh2_session_handshake(ssh, fd) == 0 else {
            // 被 shutdown 打断时握手也会失败，别报成「握手失败」误导用户。
            if isCancelled { throw AppError.cancelled }
            throw AppError.message("SSH 握手失败：\(Self.lastError(ssh))")
        }

        if isCancelled { throw AppError.cancelled }
        let authResult = user.withCString { userPointer in
            password.withCString { passwordPointer in
                libssh2_userauth_password_ex(
                    ssh,
                    userPointer,
                    UInt32(user.utf8.count),
                    passwordPointer,
                    UInt32(password.utf8.count),
                    nil
                )
            }
        }
        guard authResult == 0 else {
            let message = Self.lastError(ssh)
            "auth failed".withCString { description in
                "".withCString { language in
                    libssh2_session_disconnect_ex(ssh, 11, description, language)
                }
            }
            if isCancelled { throw AppError.cancelled }
            throw AppError.message("SSH 密码认证失败：\(message)")
        }
        if isCancelled { throw AppError.cancelled }

        self.session = ssh
        self.socketFD = fd
        sessionFreed = true
        adopted = true
    }

    /// 非阻塞 connect + poll 自己控时。
    ///
    /// 阻塞式 `connect()` 在目标不在同一网段时不会按 SO_SNDTIMEO 返回，
    /// 而要等内核把 SYN 重试完（约 75 秒）——界面就一直卡在「正在连接」。
    /// 这里改成 200ms 切片轮询，超时可控，中途还能被 cancelAttempt() 打断。
    private func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AppError.message("无法创建 TCP socket")
        }

        // 所有失败出口都走这里：先摘掉 pendingFD 再 close，
        // 免得 fd 号被系统复用后，后续的 cancelAttempt 误伤别人的 socket。
        func abort(_ error: Error) -> Error {
            setPendingFD(-1)
            Darwin.close(fd)
            return error
        }

        var socketTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let parsed = host.withCString { pointer in
            inet_pton(AF_INET, pointer, &address.sin_addr)
        }
        guard parsed == 1 else {
            throw abort(AppError.message("路由器地址不是有效的 IPv4"))
        }

        let flags = fcntl(fd, F_GETFL, 0)
        let baseFlags = flags < 0 ? Int32(0) : flags
        _ = fcntl(fd, F_SETFL, baseFlags | O_NONBLOCK)
        setPendingFD(fd)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let code = errno
            if isCancelled {
                throw abort(AppError.cancelled)
            }
            guard code == EINPROGRESS || code == EALREADY else {
                throw abort(AppError.message(
                    "TCP 连接失败：\(String(cString: strerror(code)))（errno \(code)）"
                ))
            }

            let deadline = Date().addingTimeInterval(timeout)
            var connected = false
            while !connected {
                if isCancelled {
                    throw abort(AppError.cancelled)
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready > 0 {
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                    if socketError != 0 {
                        throw abort(AppError.message(
                            "TCP 连接失败：\(String(cString: strerror(socketError)))"
                        ))
                    }
                    connected = true
                } else if ready == 0 {
                    if Date() > deadline {
                        throw abort(AppError.message(
                            "连接超时：\(Int(timeout)) 秒内路由器没有响应，请确认手机和路由器在同一网段。"
                        ))
                    }
                } else {
                    let code = errno
                    if code == EINTR { continue }
                    throw abort(AppError.message(
                        "TCP 连接失败：\(String(cString: strerror(code)))（errno \(code)）"
                    ))
                }
            }
        }

        // 恢复阻塞模式，后续 libssh2 读写靠 SO_RCVTIMEO 控时。
        _ = fcntl(fd, F_SETFL, baseFlags)
        return fd
    }

    /// 跑一条命令，把它的标准输出整段读回来。
    ///
    /// `timeout` 是**整条命令**的读超时（默认 30 秒）：读不到数据时按 EAGAIN
    /// 退避重试，超过这个时间就报「读取 SSH 输出超时」。订阅下载那种要 curl
    /// 几十秒的命令得自己把值放大，否则界面只会看到一条超时错误。
    func execute(_ command: String, timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                guard let session = self.session else {
                    continuation.resume(throwing: AppError.notConnected)
                    return
                }
                guard let channel = "session".withCString({ channelType in
                    libssh2_channel_open_ex(
                        session,
                        channelType,
                        7,
                        2 * 1024 * 1024,
                        32768,
                        nil,
                        0
                    )
                }) else {
                    continuation.resume(throwing: AppError.message(
                        "打开 SSH 通道失败：\(Self.lastError(session))"
                    ))
                    return
                }
                defer {
                    libssh2_channel_free(channel)
                }
                let execResult = command.withCString { pointer in
                    "exec".withCString { request in
                        libssh2_channel_process_startup(
                            channel,
                            request,
                            4,
                            pointer,
                            UInt32(command.utf8.count)
                        )
                    }
                }
                guard execResult == 0 else {
                    continuation.resume(throwing: AppError.message(
                        "执行 SSH 命令失败：\(Self.lastError(session))"
                    ))
                    return
                }

                var output = Data()
                output.reserveCapacity(16 * 1024)
                var buffer = [CChar](repeating: 0, count: 16 * 1024)
                // Blocking mode should never spin, but a socket timeout can surface
                // as EAGAIN. Back off with a sleep and a hard deadline instead of
                // hammering the channel in a tight loop (that used to burn phone
                // CPU and keep the router's shell busy).
                let deadline = Date().addingTimeInterval(max(timeout, 5))
                while true {
                    let read = buffer.withUnsafeMutableBufferPointer { pointer in
                        libssh2_channel_read_ex(
                            channel,
                            0,
                            pointer.baseAddress,
                            pointer.count
                        )
                    }
                    if read > 0 {
                        output.append(contentsOf: buffer.prefix(read).map { UInt8(bitPattern: $0) })
                    } else if read == 0 {
                        break
                    } else if read == Int(LIBSSH2_ERROR_EAGAIN) {
                        if Date() > deadline {
                            continuation.resume(throwing: AppError.message("读取 SSH 输出超时"))
                            return
                        }
                        usleep(20_000)
                    } else {
                        continuation.resume(throwing: AppError.message(
                            "读取 SSH 输出失败：\(Self.lastError(session))"
                        ))
                        return
                    }
                }
                continuation.resume(returning: String(decoding: output, as: UTF8.self))
            }
        }
    }

    func disconnect() {
        queue.async {
            self.closeLocked()
        }
    }

    private func closeLocked() {
        if socketFD >= 0 {
            Darwin.shutdown(socketFD, SHUT_RDWR)
        }
        if let session {
            "bye".withCString { description in
                "".withCString { language in
                    libssh2_session_disconnect_ex(session, 11, description, language)
                }
            }
            libssh2_session_free(session)
            self.session = nil
        }
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private static func lastError(_ session: OpaquePointer) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        let code = libssh2_session_last_error(session, &message, &length, 0)
        if let message {
            return String(cString: message)
        }
        return "libssh2 错误 \(code)"
    }
}
