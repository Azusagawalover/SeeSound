import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    private var packet:SharePacket?
    override func viewDidLoad() {
        super.viewDidLoad();title = "存入见声收件箱";placeholder = "可补充说明（图片在见声内识字）"
        navigationController?.navigationBar.topItem?.rightBarButtonItem?.title = "保存"
        Task { await prepare() }
    }
    override func isContentValid() -> Bool { packet != nil && contentText.count <= 12000 }
    override func didSelectPost() {
        guard var packet else { return }
        if !contentText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { packet.text = contentText }
        do { try ShareInboxStore().save(packet);extensionContext?.completeRequest(returningItems:[],completionHandler:nil) }
        catch { showError(error.localizedDescription) }
    }
    private func prepare() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard providers.count == 1,let provider = providers.first else { showError("每次请选择一段文字或一张图片。");return }
        do {
            var value = SharePacket()
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                value.image = try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier:UTType.image.identifier) { url,error in
                        do { if let error { throw error };guard let url,try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 20*1024*1024 else { throw ShareInboxError.invalid };continuation.resume(returning:try Data(contentsOf:url)) } catch { continuation.resume(throwing:error) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                value.text = try await withCheckedThrowingContinuation { continuation in provider.loadItem(forTypeIdentifier:UTType.plainText.identifier,options:nil) { item,error in
                    if let error { continuation.resume(throwing:error) } else if let text = item as? String { continuation.resume(returning:text) } else { continuation.resume(throwing:ShareInboxError.invalid) }
                } }
            } else { throw ShareInboxError.invalid }
            try value.validate();packet = value;if value.image == nil { textView.text = value.text };validateContent()
        } catch { showError(error.localizedDescription) }
    }
    private func showError(_ message:String) {
        let alert = UIAlertController(title:"未能保存",message:message,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"返回",style:.cancel));present(alert,animated:true)
    }
}
