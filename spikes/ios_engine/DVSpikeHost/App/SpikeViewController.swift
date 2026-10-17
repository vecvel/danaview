import UIKit

/// Minimal UI for the background experiment: one button per mode, a status label the UI test
/// reads, and the running log. Launch argument `-dvExperiment <mode>` starts a mode immediately.
final class SpikeViewController: UIViewController {
  private let status = UILabel()
  private let logView = UITextView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.accessibilityIdentifier = "status"
    status.numberOfLines = 0
    status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    status.text = "idle " + BackgroundExperiment.deviceFacts().joined(separator: " ")
    logView.isEditable = false
    logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    logView.accessibilityIdentifier = "log"

    let buttons = BackgroundExperiment.Mode.allCases.map { mode -> UIButton in
      let b = UIButton(type: .system)
      b.setTitle("Background export: \(mode.rawValue)", for: .normal)
      b.accessibilityIdentifier = "start-\(mode.rawValue)"
      b.addAction(UIAction { _ in BackgroundExperiment.shared.start(mode) }, for: .touchUpInside)
      return b
    }
    let stack = UIStackView(arrangedSubviews: buttons + [status, logView])
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])

    BackgroundExperiment.shared.onUpdate = { [weak self] line in
      guard let self else { return }
      self.logView.text = BackgroundExperiment.shared.lines.joined(separator: "\n")
      self.status.text = (BackgroundExperiment.shared.running ? "running " : "done ") + line
    }

    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-dvExperiment"), i + 1 < args.count,
      let mode = BackgroundExperiment.Mode(rawValue: args[i + 1])
    {
      let seconds = args.firstIndex(of: "-dvSeconds").flatMap { Int(args[$0 + 1]) } ?? 120
      BackgroundExperiment.shared.start(mode, seconds: seconds)
    }
  }
}
