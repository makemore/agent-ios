import SwiftUI
import AgentClient

/// Task list view
public struct TaskListView: View {
    let config: ChatWidgetConfig
    
    @State private var tasks: [TaskItem] = []
    @State private var isLoading: Bool = false
    @State private var error: String?
    
    public var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task { await loadTasks() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 48))
                        .foregroundColor(config.primaryColor.opacity(0.5))
                    Text("No tasks yet")
                        .font(.headline)
                    Text("Tasks will appear here as the agent works")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tasks) { task in
                            TaskRowView(task: task, config: config)
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            await loadTasks()
        }
    }
    
    private func loadTasks() async {
        isLoading = true
        error = nil
        
        // TODO: Implement task loading from API
        // For now, just show empty state
        tasks = []
        
        isLoading = false
    }
}

/// Task row view
struct TaskRowView: View {
    let task: TaskItem
    let config: ChatWidgetConfig
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // State indicator
            Text(task.state.icon)
                .font(.title3)
                .foregroundColor(stateColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .strikethrough(task.state == .complete || task.state == .cancelled)
                
                if let description = task.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(PlatformColors.systemGray6)
        .cornerRadius(8)
    }
    
    private var stateColor: Color {
        switch task.state {
        case .notStarted:
            return .secondary
        case .inProgress:
            return config.primaryColor
        case .complete:
            return .green
        case .cancelled:
            return .red
        }
    }
}

#if DEBUG
struct TaskListView_Previews: PreviewProvider {
    static var previews: some View {
        TaskListView(config: ChatWidgetConfig())
    }
}
#endif

