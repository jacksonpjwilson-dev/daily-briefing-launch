import SwiftUI
import AVFoundation
import EventKit

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: BriefingController
    @State private var status: String?
    @State private var addingShift = false
    @State private var aiToken = ""
    @State private var monitorToken = ""
    var body: some View {
        Form {
            Section("Personalize") {
                TextField("Name", text: $settings.value.name)
                Picker("Appearance", selection: $settings.value.appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                Toggle("Fahrenheit", isOn: $settings.value.fahrenheit)
                Picker("Widget highlight", selection: $settings.value.widgetSection) {
                    ForEach(SectionKind.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                NavigationLink("Calendars & permissions") { connections }
                Picker("Work schedule source", selection: $settings.value.scheduleSource) {
                    Text("Work calendar + overrides").tag("calendar"); Text("Manual shifts").tag("manual")
                }
                Picker("Work calendar", selection: $settings.value.workCalendarID) {
                    Text("None").tag("")
                    ForEach(controller.calendar.calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                }
                Stepper("Lead time: \(settings.value.scheduling.leadMinutes) minutes", value: $settings.value.scheduling.leadMinutes, in: 0...240, step: 5)
                DatePicker("Weekday fallback", selection: minuteBinding(\.scheduling.weekdayMinute), displayedComponents: .hourAndMinute)
                DatePicker("Weekend fallback", selection: minuteBinding(\.scheduling.weekendMinute), displayedComponents: .hourAndMinute)
                Toggle("Briefings on days off", isOn: $settings.value.scheduling.deliverOnDaysOff)
                NavigationLink("Manual shift overrides (\(settings.value.manualShifts.count))") { shifts }
            } header: { Text("Briefing schedule") } footer: {
                Text("A shift's earliest start sets its briefing time. Manual entries override calendar shifts on the same date. Times follow your iPhone time zone. Local notifications remind you to open the app; iOS chooses when background refresh runs.")
            }
            Section("Information cards") {
                NavigationLink("Order & visibility") { cardOrdering }
                TextField("News RSS URL", text: $settings.value.newsFeed).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("News topics (comma separated)", text: $settings.value.newsTopics)
                TextField("Sports teams", text: $settings.value.teams)
                TextField("ICAO airports", text: $settings.value.airports).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Text("Email and sports show connection boundaries until supported providers are configured. No scores or inbox messages are bundled.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Briefing reminders", isOn: $settings.value.notificationsEnabled)
                    .onChange(of: settings.value.notificationsEnabled) { _, enabled in
                        Task {
                            if enabled {
                                do { settings.value.notificationsEnabled = try await NotificationService.request() }
                                catch { status = error.localizedDescription; settings.value.notificationsEnabled = false }
                            }
                            if !settings.value.notificationsEnabled { try? await NotificationService.schedule(dates: [], preferences: settings.value) }
                        }
                    }
                Toggle("Quiet hours", isOn: $settings.value.notificationPolicy.quietEnabled)
                if settings.value.notificationPolicy.quietEnabled {
                    DatePicker("Quiet from", selection: minuteBinding(\.notificationPolicy.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minuteBinding(\.notificationPolicy.quietEnd), displayedComponents: .hourAndMinute)
                    Text("Reminders inside quiet hours are skipped. They are not delayed.").font(.caption)
                }
                Text("Remote delivery requires a compatible push server, an APNs entitlement, and device registration. No server is connected in this build.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Summary length", selection: $settings.value.summaryLength) {
                    Text("Quick · ~30 seconds").tag("Quick"); Text("Standard · ~2 minutes").tag("Standard"); Text("Detailed").tag("Detailed")
                }
                TextField("AI HTTPS endpoint", text: $settings.value.aiEndpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onChange(of: settings.value.aiEndpoint) { _, _ in settings.value.aiConsent = false }
                SecureField("AI bearer token", text: $aiToken)
                Button("Save AI token to Keychain") { saveSecret(aiToken, service: "ai", endpoint: settings.value.aiEndpoint); aiToken = "" }
                Toggle("Allow sending my briefing to this AI", isOn: $settings.value.aiConsent)
                Text("When enabled, fresh visible sections—including private calendar and reminder content, and email if connected—are sent to your endpoint to generate a summary. Review the provider's retention policy. Turning this off stops future uploads; stored provider copies must be deleted with that provider.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Optional AI · G.I.L.E.S. compatible boundary") }
            Section("Spoken briefing") {
                Slider(value: $settings.value.speechRate, in: 0.3...0.6) { Text("Speech rate") }
                Picker("System voice", selection: $settings.value.voiceID) {
                    Text("Default").tag("")
                    ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) }
                }
            }
            Section {
                Toggle("iCloud sync (restart required)", isOn: $settings.value.cloudSync)
                Stepper("Keep history for \(settings.value.retentionDays) days", value: $settings.value.retentionDays, in: 7...365, step: 1)
                Text("Local storage is the default. iCloud needs your own signed CloudKit container and entitlements. Configure the identifiers in the native project before enabling it. Widgets and Apple Watch may display briefing content; hide sensitive sections before refreshing.").font(.caption).foregroundStyle(.secondary)
                Button("Open system privacy settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                Button("End shift Live Activity") { Task { await ShiftActivities.endAll() } }
            } header: { Text("Privacy & data") }
            Section("Head Quarter monitoring") {
                TextField("Monitoring HTTPS endpoint", text: $settings.value.monitoringEndpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Monitoring bearer token", text: $monitorToken)
                Button("Save monitoring token") { saveSecret(monitorToken, service: "monitoring", endpoint: settings.value.monitoringEndpoint); monitorToken = "" }
                Button("Send health report") {
                    guard let endpoint = URL(string: settings.value.monitoringEndpoint) else { status = "Configure a compatible HTTPS endpoint first."; return }
                    Task { do { try await HTTPSHealthReporter(endpoint: endpoint).send(controller.healthReport); status = "Health report accepted." } catch { status = error.localizedDescription } }
                }
                Text("Not connected automatically. Sends provider states, refresh times, failure counts and build metadata. Does not include briefing contents. A successful HTTP response confirms receipt, not full Head Quarter compatibility.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Apply settings & refresh") { Task { await controller.refresh(); status = "Settings saved. Review Today for provider and delivery status." } }.disabled(controller.phase == .loading)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Settings")
            .onDisappear { Task { await controller.refresh() } }
    }
    private var connections: some View {
        Form {
            Section("Calendar access") {
                Text("Calendar status: \(controller.calendar.status == .fullAccess ? "Authorized" : "Not authorized")")
                Button("Allow reading calendars") { Task { do { try await controller.calendar.request() } catch { status = error.localizedDescription } } }
                ForEach(controller.calendar.calendars, id: \.calendarIdentifier) { calendar in
                    Toggle(calendar.title, isOn: Binding(get: { settings.value.calendarIDs.contains(calendar.calendarIdentifier) }, set: { enabled in
                        if enabled { settings.value.calendarIDs.insert(calendar.calendarIdentifier) } else { settings.value.calendarIDs.remove(calendar.calendarIdentifier) }
                    }))
                }
                Text("Google calendars synchronized to Apple Calendar appear here. Calendar events are read only.").font(.caption)
            }
            Section("Other permissions") {
                Button("Allow Reminders") { Task { let result = await controller.calendar.reminders(request: true); status = result.message.isEmpty ? "Reminders enabled." : result.message } }
                Button("Allow location for WeatherKit") { controller.location.request() }
                Text("WeatherKit also needs an Apple Developer capability on your signed app. Location is requested only for weather; background location tracking is disabled.").font(.caption)
            }
            if let status { Text(status).font(.caption) }
        }.navigationTitle("Connections")
    }
    private var shifts: some View {
        List {
            ForEach(settings.value.manualShifts) { shift in
                VStack(alignment: .leading) {
                    Text(shift.title).font(.headline)
                    Text("\(shift.start.formatted()) – \(shift.end.formatted())").font(.caption)
                }
            }.onDelete { settings.value.manualShifts.remove(atOffsets: $0) }
            Button("Add shift", systemImage: "plus") { addingShift = true }
        }.navigationTitle("Manual shifts").sheet(isPresented: $addingShift) {
            ShiftEditor { shift in settings.value.manualShifts.append(shift) }
        }
    }
    private var cardOrdering: some View {
        List {
            ForEach(settings.value.sectionOrder) { kind in
                Toggle(isOn: Binding(get: { !settings.value.hiddenSections.contains(kind) }, set: { visible in
                    if visible { settings.value.hiddenSections.remove(kind) } else { settings.value.hiddenSections.insert(kind) }
                })) { Label(kind.title, systemImage: kind.symbol) }
            }.onMove { settings.value.sectionOrder.move(fromOffsets: $0, toOffset: $1) }
        }.environment(\.editMode, .constant(.active)).navigationTitle("Your cards")
    }
    private func minuteBinding(_ keyPath: WritableKeyPath<AppPreferences, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = settings.value[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            settings.value[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }
    private func saveSecret(_ value: String, service: String, endpoint: String) {
        guard let url = URL(string: endpoint), let account = CredentialScope.account(service: service, endpoint: url) else {
            status = "Enter a valid HTTPS endpoint before saving its token."; return
        }
        do { try KeychainStore.save(value, account: account); status = value.isEmpty ? "Token removed." : "Token saved securely." }
        catch { status = error.localizedDescription }
    }
}
private struct ShiftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shift = ManualShift()
    let save: (ManualShift) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $shift.title)
                DatePicker("Start", selection: $shift.start)
                DatePicker("End", selection: $shift.end, in: shift.start...)
                if shift.end <= shift.start { Text("End must follow start.").foregroundStyle(.orange) }
            }.navigationTitle("Add work shift").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(shift); dismiss() }.disabled(shift.end <= shift.start || shift.title.isEmpty) }
            }
        }
    }
}
