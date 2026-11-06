import SwiftUI
import Photos
import PhotosUI
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
///
/// v2.4.14：隐藏照片不再混进主网格，改成导航栏右上角一个「眼睛划掉」入口，
/// 点进去是单独的一页（已隐藏），里面只放隐藏照片。主网格因此和系统「最近项目」
/// 同序；找隐藏照片也不用在几百张普通照片里翻。入口**常驻**（用户 2026-11-06 定），
/// 一张隐藏照片都没有时点进去看到的是「没有隐藏的照片」。
private struct BackgroundPhotoGrid: View {
    var onCancel: () -> Void
    var onPick: (UIImage) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// 主网格：不含隐藏照片。
    @State private var assets: [PHAsset] = []
    /// 「已隐藏」那一页：只含隐藏照片。
    @State private var hiddenAssets: [PHAsset] = []
    @State private var loading = true
    /// 正在把某张原图读出来（iCloud 上的照片可能要等几秒）。
    @State private var reading = false
    @State private var errorText: String?
    /// 是否已经推到「已隐藏」那一页。
    @State private var showHidden = false
    /// 系统选择器的呈现开关与选中项。
    ///
    /// 为什么「已隐藏」页还要留一条系统选择器的路：iOS 16 起「已隐藏」相簿默认带 Face ID 锁，
    /// **锁着时系统不给任何 App 下发隐藏资产**（Apple 文档原话：even if the includeHiddenAssets
    /// fetch option is true），只有 `PhotosPicker` 这种系统托管的选择器能由用户亲手交出来。
    @State private var showSystemPicker = false
    @State private var systemPickItem: PhotosPickerItem?

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 换页时把上一页的读图错误收掉，免得错误文案跟到另一页去。
                        errorText = nil
                        showHidden = true
                    } label: {
                        Image(systemName: "eye.slash")
                    }
                    .accessibilityLabel("已隐藏")
                }
            }
            .navigationDestination(isPresented: $showHidden) { hiddenPage }
            .task { await prepare() }
            // 去「设置」关掉隐藏相簿的 Face ID 锁再回来，这里得重新取一次，
            // 否则得先退出选图、再进一次才看得到（`.task` 不会因为回到前台重跑）。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                guard status == .authorized || status == .limited else { return }
                hiddenAssets = PhotoLibrary.hiddenImages()
            }
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
                tileGrid(assets)
            }
        case .denied, .restricted:
            denied
        default:
            ProgressView().controlSize(.large)
        }
    }

    /// 「已隐藏」页：用 push 而不是在主网格里切数据源——`NavigationStack` 只盖上一层，
    /// 底下那个 `ScrollView` 不销毁，返回时还在原来那一屏（跟裁切页「取消」同一个思路）。
    @ViewBuilder private var hiddenPage: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            if hiddenAssets.isEmpty {
                hiddenEmptyState
            } else {
                tileGrid(hiddenAssets)
            }
            if reading { readingOverlay }
        }
        .navigationTitle("已隐藏")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $showSystemPicker,
                      selection: $systemPickItem,
                      matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: systemPickItem) { _, item in
            handleSystemPick(item)
        }
    }

    /// 隐藏页的空态。
    ///
    /// 到这一版才把病因说准：用户「显示已隐藏的相册」是开着的，卡住的是**隐藏相簿的
    /// Face ID 锁**（iOS 16 起默认开）。Apple 文档写明：锁着时系统不返回隐藏资产，
    /// `includeHiddenAssets` 也没用；**只有 PhotosPicker 能由用户亲手把隐藏照片交给 App**。
    /// 所以空态给两条路——系统选择器（不用关锁），或去关锁后让这个网格直接列出来。
    private var hiddenEmptyState: some View {
        VStack(spacing: 14) {
            message("这里读不到隐藏照片",
                    note: "iOS 给「已隐藏」相簿默认上了 Face ID 锁，锁着时系统不会把它交给任何 App。下面用系统选择器可以挑（进去切到「相簿 › 已隐藏」）；想让它直接出现在这个网格里，去「设置 › App › 照片」把「使用 Face ID」关掉。")
            Button {
                showSystemPicker = true
            } label: {
                Label("用系统相册选择", systemImage: "photo.on.rectangle.angled")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            if status == .limited {
                Button("管理可访问的照片") { manageLimited() }
                    .font(.footnote.weight(.semibold))
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    /// 系统选择器交回来的图，走和网格同一条路：读原始数据 → 烘正方向 → 交给裁切页。
    private func handleSystemPick(_ item: PhotosPickerItem?) {
        guard let item else { return }
        reading = true
        errorText = nil
        Task { @MainActor in
            let data = try? await item.loadTransferable(type: Data.self)
            systemPickItem = nil
            guard let data, let raw = UIImage(data: data) else {
                reading = false
                errorText = "这张照片读不出来，换一张试试"
                return
            }
            reading = false
            onPick(BackgroundCropper.upright(raw, maxSide: 3000))
        }
    }

    private func tileGrid(_ list: [PHAsset]) -> some View {
        PhotoTileGrid(
            assets: list,
            showsLimitedBar: status == .limited,
            notice: errorText,
            onManage: manageLimited,
            onPick: pick
        )
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

    private func message(_ text: String, note: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 2)
            }
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
        // 两批一起取：主网格排除隐藏，分类页只留隐藏。
        // 隐藏这批**不能**靠全局 fetch + includeHiddenAssets（v2.4.13/2.4.14 就是这么写的，
        // 用户机上照样一张都取不到），要直接问系统「已隐藏」那个智能相簿。
        assets = PhotoLibrary.images(includeHidden: false)
        hiddenAssets = PhotoLibrary.hiddenImages()
        loading = false
    }

    private func manageLimited() {
        guard let vc = PhotoLibrary.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
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

/// 普通照片和隐藏照片共用的网格：三列、间距 2pt、按创建时间倒序。
/// 顶部两条提示也一起搬进来，两页的样式就不会各走各的。
private struct PhotoTileGrid: View {
    let assets: [PHAsset]
    let showsLimitedBar: Bool
    let notice: String?
    let onManage: () -> Void
    let onPick: (PHAsset) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            if showsLimitedBar { limitedBar }

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    Button {
                        onPick(asset)
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
            Button("管理") { onManage() }
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
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

    /// 取图列表。`includeHidden: false` = 主网格（跟系统「最近项目」一致）；
    /// `true` = 带上隐藏资产，调用方按 `isHidden` 自己筛。
    static func images(includeHidden: Bool) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d",
                                        PHAssetMediaType.image.rawValue)
        options.includeHiddenAssets = includeHidden
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        return list
    }

    /// 只取「已隐藏」里的照片。
    ///
    /// **为什么不用全局 fetch + `includeHiddenAssets = true`**：v2.4.13 那么写，用户机上
    /// 一张都拿不到（2026-11-06 实测）。系统把隐藏资产挂在专门的智能相簿
    /// `smartAlbumAllHidden` 下，直接对相簿 fetch 才稳定。相簿里不筛 `mediaType`，
    /// 取完在内存里挑图片——隐藏的照片通常没几张，这点开销不值得再加 predicate 冒险。
    static func hiddenImages() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = true

        var list: [PHAsset] = []
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                            subtype: .smartAlbumAllHidden,
                                                            options: nil)
        albums.enumerateObjects { album, _, _ in
            let result = PHAsset.fetchAssets(in: album, options: options)
            result.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image { list.append(asset) }
            }
        }
        // 兜底：某些系统版本上「已隐藏」相簿取不到，但全局 fetch 能拿到 hidden 资产。
        if list.isEmpty {
            list = images(includeHidden: true).filter { $0.isHidden }
        }
        return list
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
