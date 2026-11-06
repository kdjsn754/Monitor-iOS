import SwiftUI
import Photos
import UIKit

/// 自建相册网格 + 裁切的整条流程（v2.4.12）。
///
/// **为什么不用系统的 `PhotosPicker`**：它每次呈现都是一个全新的
/// `PHPickerViewController`，位置永远从顶部开始，系统也没有给「恢复滚动位置」的接口。
/// v2.4.11 在裁切页点取消时把系统选择器再弹一次，结果用户翻到一半的位置全丢，
/// 还得重新往下翻（这是用户第三次反馈同一个诉求）。
///
/// 换成自己画的网格之后：网格和裁切页在**同一个视图树**里，裁切只是盖在上面的一层
/// （`ZStack` + `zIndex`），网格从头到尾没有被销毁，`ScrollView` 的 contentOffset
/// 天然保留——取消就是收掉上面那一层，视线回到原来那一屏。
struct BackgroundPickerFlow: View {
    /// 裁完回传：成品 + 原图（原图留着以后再「调整」，不至于回不到原始像素）。
    var onUse: (UIImage, UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 正在裁的那张原图；nil = 停在网格上（或刚取消回来）。
    @State private var pending: UIImage?

    var body: some View {
        ZStack {
            BackgroundPhotoGrid(
                onCancel: { dismiss() },
                onPick: { image in pending = image }
            )

            if let pending {
                BackgroundCropView(
                    image: pending,
                    // 取消 = 只收掉这一层，网格原地不动（本次的核心诉求）。
                    onCancel: { self.pending = nil },
                    onUse: { cropped in
                        onUse(cropped, pending)
                        dismiss()
                    }
                )
                .zIndex(1)
            }
        }
        .background(Color.black)
    }
}

/// 相册网格本体：三列缩略图，按创建时间倒序（跟系统相册的「最近项目」一致）。
private struct BackgroundPhotoGrid: View {
    var onCancel: () -> Void
    var onPick: (UIImage) -> Void

    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var loading = true
    /// 正在把某张原图读出来（iCloud 上的照片可能要等几秒）。
    @State private var reading = false
    @State private var errorText: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                content
                if reading { readingOverlay }
            }
            .navigationTitle("选择照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
                }
            }
            .task { await prepare() }
        }
    }

    // MARK: - 状态分支

    @ViewBuilder private var content: some View {
        switch status {
        case .authorized, .limited:
            if loading {
                ProgressView().controlSize(.large)
            } else if assets.isEmpty {
                message("相册里没有可用的照片")
            } else {
                grid
            }
        case .denied, .restricted:
            denied
        default:
            ProgressView().controlSize(.large)
        }
    }

    private var grid: some View {
        ScrollView {
            if status == .limited { limitedBar }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    Button {
                        pick(asset)
                    } label: {
                        PhotoThumbCell(asset: asset)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// 只授权了部分照片时给一条提示：不然用户会以为「相册里的图都没了」。
    private var limitedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.caption)
            Text("当前只显示你授权过的照片")
                .font(.caption)
            Spacer(minLength: 4)
            Button("管理") {
                if let vc = PhotoLibrary.topViewController() {
                    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var denied: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("没有相册访问权限")
                .font(.headline)
            Text("到「设置 › 隐私与安全性 › 照片」里允许访问，才能挑一张做背景")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var readingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取原图…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - 权限与数据

    private func prepare() async {
        var current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            current = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        status = current
        guard current == .authorized || current == .limited else {
            loading = false
            return
        }
        loadAssets()
        loading = false
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d",
                                        PHAssetMediaType.image.rawValue)
        // v2.4.13：把「已隐藏」的照片也取出来。
        // 系统相册的「已隐藏」相簿能选、`PhotosPicker` 也能选，自建网格里选不到就是倒退
        // （用户 2026-11-06 反馈）。这里只负责让 PhotoKit 别把 hidden 资产过滤掉；
        // 如果用户在「设置 › 照片」里关掉了「显示已隐藏的相册」，系统根本不下发这批资产，
        // 代码侧没有任何 API 能绕过，也没有 API 能查到那个开关的状态——别在这儿乱试。
        options.includeHiddenAssets = true
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    private func pick(_ asset: PHAsset) {
        guard !reading else { return }
        reading = true
        errorText = nil
        Task { @MainActor in
            let raw = await PhotoLibrary.fullImage(asset)
            reading = false
            guard let raw else {
                errorText = "这张照片读不出来，换一张试试（iCloud 原图需要先下载）"
                return
            }
            // 方向在这里烘进像素——和 v2.4.11 一样放在主线程做，避免 UIKit 绘制跨线程。
            onPick(BackgroundCropper.upright(raw, maxSide: 3000))
        }
    }
}

/// 单个缩略图格子：先占一块灰底，缩略图到了再填上。
private struct PhotoThumbCell: View {
    let asset: PHAsset
    @State private var image: UIImage?
    /// 当前这张图属于哪个 asset。
    /// 滚动时格子可能被复用，只认 id 对得上的那一张，避免串图。
    @State private var loadedID: String?

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                if loadedID == asset.localIdentifier, image != nil { return }
                let loaded = await PhotoLibrary.thumbnail(asset)
                guard !Task.isCancelled else { return }
                image = loaded
                loadedID = asset.localIdentifier
            }
    }
}

/// PhotoKit 的几个取图入口，外加一层缩略图缓存。
///
/// 缓存是必须的：`LazyVGrid` 滚出屏幕再滚回来会重建格子，
/// 没有缓存就每次都重新向系统要一遍图，快速上下滑动时整屏发白。
enum PhotoLibrary {
    private static let cache = NSCache<NSString, UIImage>()

    /// 保证 `continuation` 只被 resume 一次。
    /// PhotoKit 在 opportunistic 模式下会回调两次（先糊后清），
    /// 直接 resume 两次会崩在 `Fatal error: SWIFT TASK CONTINUATION MISUSE`。
    final class ResumeGate {
        private var used = false
        private let lock = NSLock()
        func pass() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    static func thumbnail(_ asset: PHAsset) async -> UIImage? {
        let key = asset.localIdentifier as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let gate = ResumeGate()
        let image: UIImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 360, height: 360),
                contentMode: .aspectFill,
                options: options
            ) { result, _ in
                guard gate.pass() else { return }
                cont.resume(returning: result)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// 取原始数据再解码：比 `requestImage` 给的那份多保留一层质量，
    /// 裁切和 `downscale` 才有东西可压。
    static func fullImage(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true

        let gate = ResumeGate()
        let data: Data? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                guard gate.pass() else { return }
                cont.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return UIImage(data: data)
    }

    /// 「管理」按钮要把系统的受限相册选择器挂到当前最上层控制器上。
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var vc = window?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
