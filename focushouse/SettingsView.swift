import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("wake") private var wake = 420
    @AppStorage("bed") private var bed = 1320
    @AppStorage("schoolStart") private var schoolStart = 480
    @AppStorage("schoolEnd") private var schoolEnd = 900
    @AppStorage("hasSchool") private var hasSchool = true
    @AppStorage("useRoutine") private var useRoutine = true
    @AppStorage("autoAddToCalendar") private var autoAddToCalendar = false
    @AppStorage("askFreeTime") private var askFreeTime = false
    @AppStorage("screenTimeRest") private var screenTimeRest = false
    @AppStorage("restMinBreak", store: RestLog.defaults) private var restMinBreak = RestLog.defaultMinutes
    @AppStorage("limitSchool") private var limitSchool = WorkLimit.schoolDefault
    @AppStorage("limitOff") private var limitOff = WorkLimit.offDefault
    @AppStorage("showDamage") private var showDamage = true
    @AppStorage("weeklySummaryOn") private var summaryOn = true
    @State private var pace = Planner.pace()

    var body: some View {
        NavigationStack {
            PixelList {
                Section {
                    Toggle("Follow a routine", isOn: $useRoutine.animation())
                    if useRoutine {
                        DatePicker("Wake up", selection: minutesBinding($wake), displayedComponents: .hourAndMinute)
                        DatePicker("Bedtime", selection: minutesBinding($bed), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("My routine").pixelHeader()
                } footer: {
                    Text(useRoutine ? "Tasks are only scheduled between wake-up and bedtime\(hasSchool ? ", which are outside of school hours" : "")."
                                    : "No routine (e.g. holidays): tasks can go anywhere from 8 AM to 11 PM, around your Calendar events.")
                }
                if useRoutine {
                    Section {
                        Toggle("School on weekdays", isOn: $hasSchool.animation())
                        if hasSchool {
                            DatePicker("School starts", selection: minutesBinding($schoolStart), displayedComponents: .hourAndMinute)
                            DatePicker("School ends", selection: minutesBinding($schoolEnd), displayedComponents: .hourAndMinute)
                        }
                        NavigationLink {
                            TimetableView()
                        } label: {
                            Label("Add timetable to Calendar", systemImage: "tablecells")
                        }
                    } header: {
                        Text("School").pixelHeader()
                    } footer: {
                        Text("Turn off for school holidays. Add your timetable from a photo or PDF so plans also avoid lessons that run late, like CCAs.")
                    }
                }
                Section {
                    Toggle("Add new plans to Calendar automatically", isOn: $autoAddToCalendar)
                    Toggle("Ask when I'm free each time", isOn: $askFreeTime)
                } header: {
                    Text("Calendar").pixelHeader()
                } footer: {
                    Text("When \"Ask when I'm free\" is on, each new plan asks for your free time instead of using your routine. Calendar events are still avoided.")
                }
                Section {
                    Toggle("Count rest with Screen Time", isOn: $screenTimeRest)
                        .onChange(of: screenTimeRest) { _, on in
                            if on { Task { screenTimeRest = await ScreenTime.enable() } } else { ScreenTime.disable() }
                        }
                    Stepper("Rest after \(HomeView.duration(TimeInterval(restMinBreak * 60))) away",
                            value: $restMinBreak, in: RestLog.floorMinutes...RestLog.defaultMinutes, step: 15)
                } header: {
                    Text("Rest").pixelHeader()
                } footer: {
                    Text(screenTimeRest
                         ? "Rest is \(HomeView.duration(TimeInterval(restMinBreak * 60))) or more in a row without using your phone (counted in whole hours). \(Int(House.restGoal / 3600)) hours of rest in a day repairs your house a step. Tasks done with your phone down the whole time earn 50% more bricks."
                         : "Rest is \(HomeView.duration(TimeInterval(restMinBreak * 60))) or more in a row away from focushouse (at least 15 min). It can't see other apps, so turn on Screen Time to count only time off your whole phone.")
                }
                Section {
                    Toggle("Weekly summary", isOn: $summaryOn)
                } header: {
                    Text("Wellbeing").pixelHeader()
                } footer: {
                    Text("A page from Home's \"Your week\" card: your stress, rest and finished tasks over the last 7 days, what weighed on you most, and a few words from the on-device AI.")
                }
                Section {
                    Toggle("Show house damage on widgets", isOn: $showDamage)
                } header: {
                    Text("Widgets").pixelHeader()
                } footer: {
                    Text(showDamage ? "Widgets show your house as it is, even on hard days."
                                    : "On hard days, widgets show your rest instead of a damaged house.")
                }
                Section {
                    Stepper(value: $limitSchool, in: 60...720, step: 30) {
                        LabeledContent("School days", value: hoursAndMinutes(limitSchool))
                    }
                    Stepper(value: $limitOff, in: 60...720, step: 30) {
                        LabeledContent("Weekends & holidays", value: hoursAndMinutes(limitOff))
                    }
                } header: {
                    Text("Daily work limit").pixelHeader()
                } footer: {
                    VStack(alignment: .leading) {
                        Text("New plans add a free-time break once a day goes over this. Research links more than 5 h of study a day to more anxiety in teens.")
                        if max(limitSchool, limitOff) > WorkLimit.research {
                            Text("That's over 5 h. Consider a lower limit.").foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        PaceView(pace: $pace)
                    } label: {
                        LabeledContent("My pace", value: pace.isEmpty ? "Not learned yet" : "\(pace.count) learned")
                    }
                } footer: {
                    Text("How long tasks really take you compared with the AI's estimate.")
                }
                Section {
                    Button("Show the tour again") {
                        UserDefaults.standard.set(true, forKey: "resetHints")
                        UserDefaults.standard.set(false, forKey: "homeTourDone")
                        dismiss()
                    }
                    NavigationLink("How to connect Google Calendar") {
                        CalendarTipView()
                    }
                } header: {
                    Text("Help").pixelHeader()
                } footer: {
                    Text("Replays the tour of Home.")
                }
            }
            .pixelTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                minutes.wrappedValue = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }
}

#Preview { SettingsView() }

/// Per-category pace, its own page so Settings stays short as more kinds get learned.
private struct PaceView: View {
    @Binding var pace: [(category: String, ratio: Double, count: Int)]

    var body: some View {
        PixelList {
            Section {
                ForEach(Planner.categories, id: \.self) { category in
                    let p = pace.first { $0.category == category }
                    let ratio = p?.ratio ?? 1
                    Stepper(value: Binding { ratio } set: {
                        Planner.setPace(category: category, ratio: ($0 * 10).rounded() / 10)
                        pace = Planner.pace()
                    }, in: 0.5...3, step: 0.1) {
                        LabeledContent(category.capitalized,
                                       value: "×\(ratio.formatted(.number.precision(.fractionLength(1))))" + (p.map { " · \($0.count) tasks" } ?? " · not learned"))
                    }
                }
                if !pace.isEmpty {
                    Button("Reset my pace", role: .destructive) {
                        Planner.resetPace()
                        pace = []
                    }
                }
            } footer: {
                Text("Real time ÷ AI estimate. ×1.5 means it takes you 50% longer; new plans and stress adjust for it. The AI learns it after \(Planner.paceRunway) tasks of a kind. Set it yourself if it's off, and finished tasks keep fine-tuning it.")
            }
        }
        .navigationTitle("My pace")
    }
}
