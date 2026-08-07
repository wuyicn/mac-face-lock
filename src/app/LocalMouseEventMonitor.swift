import AppKit

@MainActor
final class LocalMouseEventMonitor {
    typealias EventHandler = (NSEvent) -> NSEvent?
    typealias AddMonitor = (
        NSEvent.EventTypeMask,
        @escaping EventHandler
    ) -> Any?
    typealias RemoveMonitor = (Any) -> Void
    typealias KeyWindowNumber = @MainActor () -> Int?

    private let recorder: UIEventTraceRecorder
    private let addMonitor: AddMonitor
    private let removeMonitor: RemoveMonitor
    private let keyWindowNumber: KeyWindowNumber
    private var monitorToken: Any?

    init(
        recorder: UIEventTraceRecorder,
        addMonitor: @escaping AddMonitor = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        },
        removeMonitor: @escaping RemoveMonitor = { token in
            NSEvent.removeMonitor(token)
        },
        keyWindowNumber: @escaping KeyWindowNumber = {
            NSApp.keyWindow?.windowNumber
        }
    ) {
        self.recorder = recorder
        self.addMonitor = addMonitor
        self.removeMonitor = removeMonitor
        self.keyWindowNumber = keyWindowNumber
    }

    func start() {
        guard monitorToken == nil else {
            return
        }
        monitorToken = addMonitor([.leftMouseDown, .leftMouseUp]) {
            [recorder, keyWindowNumber] event in
            let location = event.locationInWindow
            let traceEvent: UIEventTraceEvent?
            switch event.type {
            case .leftMouseDown:
                traceEvent = .leftMouseDown(
                    windowNumber: event.windowNumber,
                    locationX: location.x,
                    locationY: location.y,
                    keyWindowNumber: keyWindowNumber()
                )
            case .leftMouseUp:
                traceEvent = .leftMouseUp(
                    windowNumber: event.windowNumber,
                    locationX: location.x,
                    locationY: location.y,
                    keyWindowNumber: keyWindowNumber()
                )
            default:
                traceEvent = nil
            }
            if let traceEvent {
                recorder.record(traceEvent)
            }
            return event
        }
    }

    func stop() {
        guard let monitorToken else {
            return
        }
        self.monitorToken = nil
        removeMonitor(monitorToken)
    }
}
