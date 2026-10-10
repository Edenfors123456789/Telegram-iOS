import UIKit

/// Transient A-only presentation. IDs index adapter-owned, separately verified actions.
public final class HiddenChatManagementView: UIView, UITableViewDataSource, UITableViewDelegate {
    public struct Item {
        public let id: UUID
        public let title: String
        public init(id: UUID, title: String) { self.id = id; self.title = title }
    }
    public enum Failure: Error { case duplicateIdentifier }
    public var selected: ((UUID) -> Void)? {
        get { selectionHandler }
        set { if !finished { selectionHandler = newValue } }
    }
    private var selectionHandler: ((UUID) -> Void)?
    private var items: [Item]
    private var visible: [Item]
    private var finished = false
    private let search = UITextField()
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let cells = NSHashTable<UITableViewCell>.weakObjects()
    private let textColor: UIColor
    private let emptyText: String
    public var visibleIdentifiers: [UUID] { visible.map(\.id) }
    public init(items: [Item], searchPlaceholder: String, emptyText: String, background: UIColor, textColor: UIColor, accent: UIColor) throws {
        guard Set(items.map(\.id)).count == items.count else { throw Failure.duplicateIdentifier }
        self.items = items
        self.visible = items
        self.textColor = textColor
        self.emptyText = emptyText
        super.init(frame: .zero)
        backgroundColor = background
        search.placeholder = searchPlaceholder
        search.accessibilityIdentifier = "HiddenChats.Search"
        search.textContentType = nil; search.autocorrectionType = .no; search.spellCheckingType = .no
        search.autocapitalizationType = .none; search.returnKeyType = .search
        search.borderStyle = .roundedRect; search.textColor = textColor; search.tintColor = accent
        search.font = .systemFont(ofSize: 17); search.clearButtonMode = .whileEditing
        search.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        table.accessibilityIdentifier = "HiddenChats.List"
        table.dataSource = self; table.delegate = self
        table.backgroundColor = background; table.tintColor = accent
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 64
        table.keyboardDismissMode = .onDrag
        emptyLabel.textColor = textColor; emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center; emptyLabel.font = .systemFont(ofSize: 17)
        search.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search); addSubview(table)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            search.heightAnchor.constraint(equalToConstant: 44),
            table.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        ])
        updateEmptyState()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationInactive), name: UIApplication.willResignActiveNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public func updateSearch(_ query: String) {
        precondition(Thread.isMainThread)
        guard !finished else { return }
        search.text = query
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        visible = query.isEmpty ? items : items.filter { $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(query) }
        table.reloadData(); updateEmptyState()
    }
    @objc private func searchChanged() { updateSearch(search.text ?? "") }
    @discardableResult public func selectItem(_ id: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard !finished, visible.contains(where: { $0.id == id }), let callback = selectionHandler else { return false }
        invalidate()
        callback(id)
        return true
    }
    public func invalidate() {
        precondition(Thread.isMainThread)
        finished = true; selectionHandler = nil
        items.removeAll(); visible.removeAll()
        search.text = ""; search.placeholder = nil; search.isEnabled = false
        search.removeTarget(self, action: #selector(searchChanged), for: .editingChanged)
        emptyLabel.text = nil
        for cell in cells.allObjects {
            cell.textLabel?.text = nil; cell.detailTextLabel?.text = nil
            cell.accessibilityLabel = nil; cell.accessibilityIdentifier = nil
            cell.isUserInteractionEnabled = false
        }
        cells.removeAllObjects()
        table.dataSource = nil; table.delegate = nil; table.backgroundView = nil
        table.reloadData(); table.isUserInteractionEnabled = false
        isUserInteractionEnabled = false; endEditing(true)
    }
    @objc private func applicationInactive() { invalidate() }
    public override func willMove(toWindow newWindow: UIWindow?) {
        if window != nil && newWindow == nil { invalidate() }
        super.willMove(toWindow: newWindow)
    }
    private func updateEmptyState() {
        emptyLabel.text = visible.isEmpty ? emptyText : nil
        table.backgroundView = visible.isEmpty ? emptyLabel : nil
    }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { !finished && section == 0 ? visible.count : 0 }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "HiddenChat") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "HiddenChat")
        guard !finished, indexPath.section == 0, visible.indices.contains(indexPath.row) else { cell.textLabel?.text = nil; cell.detailTextLabel?.text = nil; return cell }
        let item = visible[indexPath.row]
        cell.textLabel?.text = item.title; cell.textLabel?.textColor = textColor
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = "Показывать в режиме B"; cell.detailTextLabel?.textColor = table.tintColor
        cell.backgroundColor = backgroundColor
        cell.accessibilityIdentifier = "HiddenChats.Row." + item.id.uuidString
        cell.accessibilityLabel = item.title
        cells.add(cell)
        return cell
    }
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !finished, indexPath.section == 0, visible.indices.contains(indexPath.row) else { return }
        selectItem(visible[indexPath.row].id)
    }
}
