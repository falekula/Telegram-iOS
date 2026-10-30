import Foundation
import UIKit
import PhotosUI
import AsyncDisplayKit
import Display
import AccountContext
import TelegramPresentationData

/// iOS cannot replace a signed app icon with arbitrary downloaded bytes.
/// Prepare the user's image and guide creation of a Home Screen launcher instead.
final class PersonalForkIconController: ViewController, PHPickerViewControllerDelegate {
    private let context: AccountContext
    private let preview = UIImageView()
    private let instructions = UILabel()
    private var selectedImage: UIImage?
    private var scrollTop: NSLayoutConstraint?
    private var imagePath: URL {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("personal-launcher-icon.png")
    }

    init(context: AccountContext) {
        self.context = context
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: data))
        self.title = "Ярлык со своим фото"
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.context.sharedContext.currentPresentationData.with { $0 }.theme.list.blocksBackgroundColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let data = self.context.sharedContext.currentPresentationData.with { $0 }
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        self.preview.contentMode = .scaleAspectFit
        self.preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        self.selectedImage = UIImage(contentsOfFile: self.imagePath.path)
        self.preview.image = self.selectedImage
        stack.addArrangedSubview(self.preview)
        for (title, action) in [
            ("Выбрать фотографию", #selector(self.choosePhoto)),
            ("Сохранить картинку", #selector(self.exportPhoto)),
            ("Скопировать ссылку", #selector(self.copyLink(_:))),
            ("Открыть Команды", #selector(self.openShortcuts))
        ] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17)
            button.titleLabel?.numberOfLines = 0
            button.tintColor = data.theme.list.itemAccentColor
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        self.instructions.numberOfLines = 0
        self.instructions.textColor = data.theme.list.itemPrimaryTextColor
        self.instructions.font = .systemFont(ofSize: 16)
        self.instructions.text = "Отдельный ярлык; значок приложения не меняется.\n\n1. Сохраните фото и скопируйте ссылку.\n2. В Командах добавьте «URL» со ссылкой, затем «Открыть URL».\n3. Выберите «На экран Домой» и своё фото."
        stack.addArrangedSubview(self.instructions)
        let top = scroll.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 100)
        self.scrollTop = top
        NSLayoutConstraint.activate([
            top,
            scroll.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.scrollTop?.constant = self.navigationLayout(layout: layout).navigationFrame.maxY
    }

    @objc private func choosePhoto() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        self.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                guard let self, image.size.width > 0, image.size.height > 0 else { return }
                let scale = max(400 / image.size.width, 400 / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let square = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format).image { _ in
                    image.draw(in: CGRect(x: (400 - size.width) / 2, y: (400 - size.height) / 2, width: size.width, height: size.height))
                }
                self.selectedImage = square
                self.preview.image = square
                do {
                    try FileManager.default.createDirectory(at: self.imagePath.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try square.pngData()?.write(to: self.imagePath, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    self.instructions.text = "Не удалось запомнить фото. Нажмите «Сохранить картинку» для экспорта."
                }
            }
        }
    }

    @objc private func exportPhoto() {
        guard let image = self.selectedImage else { self.choosePhoto(); return }
        let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = self.preview
        share.popoverPresentationController?.sourceRect = self.preview.bounds
        self.present(share, animated: true)
    }

    @objc private func copyLink(_ sender: UIButton) {
        UIPasteboard.general.string = "falekulagram://open"
        sender.setTitle("Скопировано", for: .normal)
        UIAccessibility.post(notification: .announcement, argument: "Ссылка скопирована")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak sender] in
            sender?.setTitle("Скопировать ссылку", for: .normal)
        }
    }

    @objc private func openShortcuts() {
        if let url = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(url) }
    }
}
