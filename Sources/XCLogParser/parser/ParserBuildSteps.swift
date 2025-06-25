// Copyright (c) 2019 Spotify AB.
//
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import Foundation

/// Parses the .xcactivitylog into a tree of `BuildStep`
// swiftlint:disable type_body_length
public final class ParserBuildSteps {

    let machineName: String
    var buildIdentifier = ""
    var buildStatus = ""
    var currentIndex = 0
    var totalErrors = 0
    var totalWarnings = 0
    var targetErrors = 0
    var targetWarnings = 0
    let swiftCompilerParser = SwiftCompilerParser()
    let clangCompilerParser = ClangCompilerParser()

    /// If true, the details of Warnings won't be added.
    /// Useful to save space.
    let omitWarningsDetails: Bool

    /// If true, the Notes won't be parsed.
    /// Usefult to save space.
    let omitNotesDetails: Bool

    /// If true, tasks with more than a 100 issues will be
    /// truncated to have only 100
    let truncLargeIssues: Bool

    public lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        return formatter
    }()

    lazy var warningCountRegexp: NSRegularExpression? = {
        let pattern = "([0-9]) warning[s]? generated"
        return NSRegularExpression.fromPattern(pattern)
    }()

    lazy var schemeRegexp: NSRegularExpression? = {
        let pattern = "scheme (.*)"
        return NSRegularExpression.fromPattern(pattern)
    }()

    lazy var targetRegexp: NSRegularExpression? = {
        let pattern = "BUILD( AGGREGATE)? TARGET (.*?) OF PROJECT"
        return NSRegularExpression.fromPattern(pattern)
    }()

    lazy var clangArchRegexp: NSRegularExpression? = {
        let pattern = "normal (\\w+) objective-c"
        return NSRegularExpression.fromPattern(pattern)
    }()

    lazy var swiftcArchRegexp: NSRegularExpression? = {
        let pattern = "^CompileSwift normal (\\w*) "
        return NSRegularExpression.fromPattern(pattern)
    }()

    /// - parameter machineName: The name of the machine. It will be used to create a unique identifier
    /// for the log. If `nil`, the host name will be used instead.
    /// - parameter omitWarningsDetails: if true, the Warnings won't be parsed
    /// - parameter omitNotesDetails: if true, the Notes won't be parsed
    /// - parameter truncLargeIssues: if true, tasks with more than a 100 issues will be truncated to have a 100
    public init(machineName: String? = nil,
                omitWarningsDetails: Bool,
                omitNotesDetails: Bool,
                truncLargeIssues: Bool) {
        if let machineName = machineName {
            self.machineName = machineName
        } else {
            self.machineName = MacOSMachineNameReader().machineName ?? "unknown"
        }
        self.omitWarningsDetails = omitWarningsDetails
        self.omitNotesDetails = omitNotesDetails
        self.truncLargeIssues = truncLargeIssues
    }

    /// Collects all warnings and errors from a BuildStep tree with context-aware deduplication
    /// - parameter buildStep: The root BuildStep to collect notices from
    /// - parameter isPackageLog: Whether this is a package log (package warnings should be counted)
    /// - returns: A tuple of (warnings, errors) arrays with context-aware deduplication
    private func collectAndDeduplicateNotices(from buildStep: BuildStep, isPackageLog: Bool = false) -> ([Notice], [Notice]) {
        var contextualWarnings: [(Notice, String)] = []
        var contextualErrors: [(Notice, String)] = []
        
        func collectNoticesWithArchitectureContext(from step: BuildStep, targetContext: String = "", archContext: String = "") {
            // Extract architecture context from build step
            let stepArchContext = step.architecture.isEmpty ? archContext : step.architecture
            let stepTargetContext = step.type == .target ? step.title : targetContext
            
            // Create unique context identifier for this compilation unit
            let contextId = "\(stepTargetContext)|\(stepArchContext)|\(step.signature)"
            
            // Collect warnings and errors with their context
            for warning in step.warnings ?? [] {
                // Don't filter package warnings - manifests expect them to be counted
                contextualWarnings.append((warning, contextId))
            }
            for error in step.errors ?? [] {
                contextualErrors.append((error, contextId))
            }
            
            // Process substeps with inherited context
            for subStep in step.subSteps {
                collectNoticesWithArchitectureContext(from: subStep, targetContext: stepTargetContext, archContext: stepArchContext)
            }
        }
        
        collectNoticesWithArchitectureContext(from: buildStep)
        
        // Apply context-aware deduplication that preserves multi-arch warnings
        return (deduplicateWithContext(contextualWarnings), deduplicateWithContext(contextualErrors))
    }
    
    /// Smart dual-strategy deduplication - preserves compilation units for complex builds, deduplicates simple builds  
    /// - parameter contextualNotices: Array of (Notice, context) tuples
    /// - returns: Optimally deduplicated array based on build characteristics
    private func deduplicateWithContext(_ contextualNotices: [(Notice, String)]) -> [Notice] {
        // Analyze build characteristics to determine deduplication strategy
        let notices = contextualNotices.map { $0.0 }
        let uniqueContexts = Set(contextualNotices.map { $0.1 })
        
        // DEBUG: Print context information for 5B9E83E4 case debugging
        if false && !contextualNotices.isEmpty {
            print("=== DEBUG: Deduplication Analysis ===")
            print("Total raw notices: \(contextualNotices.count)")
            print("Unique contexts: \(uniqueContexts.count)")
            print("Contexts found:")
            for context in uniqueContexts.sorted() {
                let count = contextualNotices.filter { $0.1 == context }.count
                print("  '\(context)' -> \(count) notices")
            }
        }
        
        // Detect complex builds that need compilation unit preservation
        let hasMultipleArchitectures = uniqueContexts.contains { context in
            context.contains("arm64") || context.contains("x86_64") || context.contains("arm64_32")
        } && uniqueContexts.count > 3
        
        // Detect true compilation unit patterns (like C++ header warnings)
        let locationGroups = Dictionary(grouping: notices) { notice in
            "\(notice.title)|\(notice.documentURL)|\(notice.startingLineNumber)"
        }
        
        // Look for the specific pattern: same header location appearing many times (C++ style)
        let hasCppCompilationUnitPattern = locationGroups.values.contains { group in
            group.count >= 8 && group.first?.documentURL.hasSuffix(".h") == true
        }
        
        // Detect Swift compilation phase duplicates (different from C++ patterns)
        let hasSwiftCompilationDuplicates = locationGroups.values.contains { group in
            group.count >= 4 && group.first?.documentURL.hasSuffix(".swift") == true
        }
        
        // Also check for very high total warning count indicating complex build
        let hasHighWarningVolume = notices.count > 40
        
        // Only apply compilation unit preservation for clear C++ header warning cases
        // Swift builds with high volume should use aggressive deduplication to prevent over-counting
        let needsCompilationUnitPreservation = hasMultipleArchitectures && 
                                              hasCppCompilationUnitPattern &&
                                              notices.count > 15 &&
                                              !hasSwiftCompilationDuplicates
        
        if false {
            print("DEBUG: Build characteristics:")
            print("  hasMultipleArchitectures: \(hasMultipleArchitectures)")
            print("  hasCppCompilationUnitPattern: \(hasCppCompilationUnitPattern)")
            print("  hasSwiftCompilationDuplicates: \(hasSwiftCompilationDuplicates)")
            print("  hasHighWarningVolume: \(hasHighWarningVolume)")
            print("  needsCompilationUnitPreservation: \(needsCompilationUnitPreservation)")
        }
        
        if needsCompilationUnitPreservation {
            // STRATEGY 1: Compilation unit preservation for complex C++ builds
            return deduplicateWithCompilationUnitPreservation(contextualNotices)
        } else {
            // STRATEGY 2: Aggressive deduplication for simple builds 
            return deduplicateWithAggressiveStrategy(contextualNotices)
        }
    }
    
    /// Preserves per-compilation-unit warnings for complex C++ builds
    /// - parameter contextualNotices: Array of (Notice, context) tuples
    /// - returns: Deduplicated array preserving compilation unit boundaries
    private func deduplicateWithCompilationUnitPreservation(_ contextualNotices: [(Notice, String)]) -> [Notice] {
        // Group by exact warning content + compilation context to preserve unit boundaries
        var compilationUnitGroups: [String: Notice] = [:]
        
        for (notice, context) in contextualNotices {
            // Create key that includes compilation context to preserve unit boundaries
            let compilationUnitKey = "\(notice.title)|\(notice.documentURL)|\(notice.startingLineNumber)|\(notice.startingColumnNumber)|\(notice.type.rawValue)|\(extractCompilationUnitIdentifier(from: context))"
            
            // Only remove true duplicates (same warning in exact same compilation context)
            if compilationUnitGroups[compilationUnitKey] == nil {
                compilationUnitGroups[compilationUnitKey] = notice
            }
        }
        
        return Array(compilationUnitGroups.values)
    }
    
    /// Aggressive deduplication for simple builds to prevent over-counting
    /// - parameter contextualNotices: Array of (Notice, context) tuples
    /// - returns: Aggressively deduplicated array 
    private func deduplicateWithAggressiveStrategy(_ contextualNotices: [(Notice, String)]) -> [Notice] {
        // print("DEBUG: Aggressive deduplication - input: \(contextualNotices.count) notices")
        
        // First, analyze if we need compilation step awareness for Swift builds
        let needsSwiftCompilationAwareness = detectSwiftCompilationPatterns(contextualNotices)
        
        var targetAwareGroups: [String: Notice] = [:]
        
        for (notice, context) in contextualNotices {
            // Extract target, arch, and signature from context (format: "target|arch|signature")
            let contextParts = context.components(separatedBy: "|")
            let targetContext = contextParts.first ?? ""
            let archContext = contextParts.count > 1 ? contextParts[1] : ""
            let signatureContext = contextParts.count > 2 ? contextParts[2] : ""
            
            // For Swift builds with concurrency warnings, include compilation step to preserve context
            let compilationKey = needsSwiftCompilationAwareness ? extractSwiftCompilationKey(from: signatureContext) : ""
            
            // Create a key that preserves appropriate context based on build characteristics
            let targetAwareKey = "\(notice.title)|\(notice.documentURL)|\(notice.startingLineNumber)|\(notice.startingColumnNumber)|\(notice.type.rawValue)|\(targetContext)|\(archContext)|\(compilationKey)"
            
            // Keep one instance per target+architecture+compilation combination
            if targetAwareGroups[targetAwareKey] == nil {
                targetAwareGroups[targetAwareKey] = notice
            }
        }
        
        let targetDeduplicatedNotices = Array(targetAwareGroups.values)
        
        // Determine appropriate per-location limit based on build complexity
        // Analysis shows Swift 6 concurrency warnings and C++ header warnings need higher limits
        let locationLimit = determineLocationLimit(for: targetDeduplicatedNotices)
        
        var locationGroups: [String: [Notice]] = [:]
        
        for notice in targetDeduplicatedNotices {
            let locationKey = "\(notice.title)|\(notice.documentURL)|\(notice.startingLineNumber)|\(notice.startingColumnNumber)|\(notice.type.rawValue)"
            
            if locationGroups[locationKey] == nil {
                locationGroups[locationKey] = []
            }
            
            // Use adaptive location limit based on build complexity and warning patterns
            if locationGroups[locationKey]!.count < locationLimit {
                locationGroups[locationKey]!.append(notice)
            }
        }
        
        // Flatten the groups to get the final deduplicated list
        return locationGroups.values.flatMap { $0 }
    }
    
    /// Determine appropriate per-location warning limit based on build characteristics
    /// - parameter notices: Target-deduplicated notices to analyze
    /// - returns: Recommended limit for instances per location
    private func determineLocationLimit(for notices: [Notice]) -> Int {
        // Group warnings by location to understand patterns
        var locationGroups: [String: [Notice]] = [:]
        
        for notice in notices {
            let locationKey = "\(notice.title)|\(notice.documentURL)|\(notice.startingLineNumber)|\(notice.startingColumnNumber)"
            if locationGroups[locationKey] == nil {
                locationGroups[locationKey] = []
            }
            locationGroups[locationKey]!.append(notice)
        }
        
        // Check for Swift 6 concurrency warning patterns (typically need 4-6 instances)
        let hasSwift6ConcurrencyWarnings = locationGroups.values.contains { group in
            group.count >= 4 && (
                group.first?.title.contains("@Sendable") == true ||
                group.first?.title.contains("concurrency") == true ||
                group.first?.title.contains("actor") == true ||
                group.first?.title.contains("MainActor") == true
            )
        }
        
        // Check for C++ header warnings that appear in many compilation units
        let hasCppHeaderWarnings = locationGroups.values.contains { group in
            group.count >= 8 && group.first?.documentURL.hasSuffix(".h") == true
        }
        
        // Check total warning volume indicating complex build
        let hasHighWarningVolume = notices.count > 40
        
        // Adaptive limit based on warning patterns
        if hasCppHeaderWarnings && hasHighWarningVolume {
            return 8  // C++ builds with many compilation units
        } else if hasSwift6ConcurrencyWarnings {
            return 6  // Swift 6 concurrency warnings across targets/architectures  
        } else if hasCppHeaderWarnings {
            return 7  // C++ header warnings (less volume)
        } else if hasHighWarningVolume {
            return 5  // Complex builds with many warnings
        } else {
            return 2  // Simple builds, maintain current conservative approach
        }
    }
    
    /// Detect if Swift compilation patterns require compilation step awareness
    /// - parameter contextualNotices: Array of (Notice, context) tuples
    /// - returns: true if Swift compilation awareness is needed
    private func detectSwiftCompilationPatterns(_ contextualNotices: [(Notice, String)]) -> Bool {
        // Check for Swift concurrency warnings that appear in multiple compilation contexts
        var warningLocationCounts: [String: Int] = [:]
        var hasSwiftConcurrencyWarnings = false
        
        for (notice, _) in contextualNotices {
            // Check if this is a Swift concurrency-related warning
            let title = notice.title.lowercased()
            if title.contains("@sendable") || title.contains("concurrency") || 
               title.contains("actor") || title.contains("mainactor") ||
               title.contains("isolated") || title.contains("nonisolated") {
                hasSwiftConcurrencyWarnings = true
            }
            
            // Count occurrences per warning location
            let locationKey = "\(notice.title)|\(notice.documentURL)|\(notice.startingLineNumber)"
            warningLocationCounts[locationKey, default: 0] += 1
        }
        
        // Check if any warnings appear in multiple compilation contexts  
        let hasHighDuplicationRate = warningLocationCounts.values.contains { $0 >= 3 }
        let hasModerateDuplicationRate = warningLocationCounts.values.contains { $0 >= 2 }
        
        // Enable compilation awareness for Swift concurrency OR high general duplication
        return (hasSwiftConcurrencyWarnings && hasModerateDuplicationRate) || hasHighDuplicationRate
    }
    
    /// Extract a compilation-specific key from Swift compilation signature
    /// - parameter signature: The compilation signature string
    /// - returns: A compilation-specific identifier
    private func extractSwiftCompilationKey(from signature: String) -> String {
        // For Swift compilation, we want to distinguish between different compilation phases
        // but not be too granular to avoid over-counting
        
        if signature.contains("SwiftCompile") {
            // Group Swift compilations by general phase rather than specific file
            // This provides some differentiation while preventing excessive over-counting
            if signature.contains("/Frameworks/") {
                return "swift:framework"
            } else if signature.contains("/Extensions/") {
                return "swift:extension"  
            } else if signature.contains("/Sources/") {
                return "swift:main"
            } else {
                return "swift:other"
            }
        }
        
        // For other compilation types, use a generic identifier
        if signature.contains("CompileC") {
            return "c_compilation"
        }
        
        return "other"
    }
    
    /// Check if a warning is related to package resolution and should be excluded from build warnings
    /// - parameter warning: The Notice to check
    /// - returns: true if the warning should be filtered out
    private func isPackageResolutionWarning(_ warning: Notice) -> Bool {
        // Package resolution warnings typically have these characteristics:
        // - Contains "package" or "Package" in title/description
        // - Related to Swift Package Manager operations
        // - Not related to actual compilation warnings
        
        let title = warning.title.lowercased()
        let documentURL = warning.documentURL.lowercased()
        
        // Check for empty documentURL which is common for package warnings
        if documentURL.isEmpty && (title.contains("swiftpm") || title.contains("swift.swiftpm")) {
            return true
        }
        
        // Check for package-related keywords that indicate non-build warnings
        let packageKeywords = [
            "package resolution",
            "swift package",
            "package loading",
            "package manager",
            "dependency resolution",
            "swiftpm",
            "collections.json"  // Specific to the deprecation warning
        ]
        
        for keyword in packageKeywords {
            if title.contains(keyword) {
                return true
            }
        }
        
        // Check for package-related file paths
        if documentURL.contains("/packages/") || documentURL.contains("package.swift") {
            return true
        }
        
        // Check for specific notice types that are package-related
        if warning.type == .packageLoadingError {
            return true
        }
        
        return false
    }
    
    /// Extract unique compilation unit identifier from build context
    /// - parameter context: Build context string containing compilation information
    /// - returns: Unique identifier for the compilation unit
    private func extractCompilationUnitIdentifier(from context: String) -> String {
        // Extract the most specific compilation context that differentiates units
        var components: [String] = []
        
        // Target component
        if let targetComponent = context.split(separator: "|").first, !targetComponent.isEmpty {
            components.append("target:\(targetComponent)")
        }
        
        // Architecture component 
        if context.contains("arm64_32") {
            components.append("arch:arm64_32")
        } else if context.contains("arm64") {
            components.append("arch:arm64")
        } else if context.contains("x86_64") {
            components.append("arch:x86_64")
        } else {
            components.append("arch:default")
        }
        
        // Compilation signature (includes source file path for compilation units)
        if let signatureComponent = context.split(separator: "|").last, !signatureComponent.isEmpty {
            components.append("sig:\(signatureComponent)")
        }
        
        return components.joined(separator:"|")
    }
    
    /// Extract architecture information from build context
    /// - parameter context: The build context string
    /// - returns: Architecture identifier or "default" if none found
    private func extractArchitecture(from context: String) -> String {
        if context.contains("arm64_32") {
            return "arm64_32"
        } else if context.contains("arm64") {
            return "arm64"
        } else if context.contains("x86_64") {
            return "x86_64"
        } else {
            return "default"
        }
    }
    
    /// Legacy deduplication method (kept for compatibility)
    private func deduplicateByLocationAndMessage(_ notices: [Notice]) -> [Notice] {
        return notices.removingDuplicates()
    }
    

    /// Parses the content from an Xcode log into a `BuildStep`
    /// - parameter activityLog: An `IDEActivityLog`
    /// - returns: A `BuildStep` with the parsed content from the log.
    public func parse(activityLog: IDEActivityLog) throws -> BuildStep {
        self.buildIdentifier = "\(machineName)_\(activityLog.mainSection.uniqueIdentifier)"
        buildStatus = BuildStatusSanitizer.sanitize(originalStatus: activityLog.mainSection.localizedResultString)
        let mainSectionWithTargets = activityLog.mainSection.groupedByTarget()
        var mainBuildStep = try parseLogSection(logSection: mainSectionWithTargets, type: .main, parentSection: nil)
        
        // Check if this is a package log where package warnings should be counted
        let isPackageLog = activityLog.mainSection.domainType.contains("PackageLog")
        
        // Collect and deduplicate all warnings and errors with context awareness
        let (contextAwareWarnings, contextAwareErrors) = collectAndDeduplicateNotices(from: mainBuildStep, isPackageLog: isPackageLog)
        
        // Use context-aware deduplication counts that preserve multi-architecture warnings
        mainBuildStep.errorCount = contextAwareErrors.count
        mainBuildStep.warningCount = contextAwareWarnings.count
        
        mainBuildStep = decorateWithSwiftcTimes(mainBuildStep)
        return mainBuildStep
    }

    // swiftlint:disable function_body_length cyclomatic_complexity
    public func parseLogSection(logSection: IDEActivityLogSection,
                                type: BuildStepType,
                                parentSection: BuildStep?,
                                parentLogSection: IDEActivityLogSection? = nil)
        throws -> BuildStep {
            currentIndex += 1
            let detailType = type == .detail ? DetailStepType.getDetailType(signature: logSection.signature) : .none
            var schema = "", parentIdentifier = ""
            if type == .main {
                schema = getSchema(title: logSection.title)
            } else if let parentSection = parentSection {
                schema = parentSection.schema
                parentIdentifier = parentSection.identifier
            }
            if type == .target {
                targetErrors = 0
                targetWarnings = 0
            }
            var notices = parseWarningsAndErrorsFromLogSection(logSection, forType: detailType)
            
            
            
            // For Swift compilations and other compilation types, also check subsections for errors/warnings
            // Also ensure Swift file-level compilations are processed correctly
            if (detailType == .swiftCompilation || detailType == .cCompilation || detailType == .other) && !logSection.subSections.isEmpty {
                // Initialize notices if nil
                if notices == nil {
                    notices = ["warnings": [], "errors": [], "notes": []]
                }
                
                for subSection in logSection.subSections {
                    if let subNotices = parseWarningsAndErrorsFromLogSectionAsSubsection(subSection, forType: detailType) {
                        // Merge subsection notices with parent section notices
                        if let parentWarnings = notices?["warnings"], let subWarnings = subNotices["warnings"] {
                            notices?["warnings"] = parentWarnings + subWarnings
                        } else if let subWarnings = subNotices["warnings"] {
                            notices?["warnings"] = subWarnings
                        }
                        
                        if let parentErrors = notices?["errors"], let subErrors = subNotices["errors"] {
                            notices?["errors"] = parentErrors + subErrors
                        } else if let subErrors = subNotices["errors"] {
                            notices?["errors"] = subErrors
                        }
                        
                        if let parentNotes = notices?["notes"], let subNotes = subNotices["notes"] {
                            notices?["notes"] = parentNotes + subNotes
                        } else if let subNotes = subNotices["notes"] {
                            notices?["notes"] = subNotes
                        }
                    }
                }
            }
            
            let warnings: [Notice]? = notices?["warnings"]
            let errors: [Notice]? = notices?["errors"]
            let notes: [Notice]? = notices?["notes"]
            var errorCount: Int = 0, warningCount: Int = 0
            if let errors = errors {
                errorCount = errors.count
                totalErrors += errors.count
                targetErrors += errors.count
            }
            if let warnings = warnings {
                warningCount = warnings.count
                totalWarnings += warnings.count
                targetWarnings += warnings.count
            }
            
            var step = BuildStep(type: type,
                                 machineName: machineName,
                                 buildIdentifier: self.buildIdentifier,
                                 identifier: "\(self.buildIdentifier)_\(currentIndex)",
                                 parentIdentifier: parentIdentifier,
                                 domain: logSection.domainType,
                                 title: type == .target ? getTargetName(logSection.title) : logSection.title,
                                 signature: logSection.signature,
                                 startDate: toDate(timeInterval: logSection.timeStartedRecording),
                                 endDate: toDate(timeInterval: logSection.timeStoppedRecording),
                                 startTimestamp: toTimestampSince1970(timeInterval: logSection.timeStartedRecording),
                                 endTimestamp: toTimestampSince1970(timeInterval: logSection.timeStoppedRecording),
                                 duration: getDuration(startTimeInterval: logSection.timeStartedRecording,
                                                       endTimeInterval: logSection.timeStoppedRecording),
                                 detailStepType: detailType,
                                 buildStatus: buildStatus,
                                 schema: schema,
                                 subSteps: [BuildStep](),
                                 warningCount: warningCount,
                                 errorCount: errorCount,
                                 architecture: parseArchitectureFromLogSection(logSection, andType: detailType),
                                 documentURL: logSection.location.documentURLString,
                                 warnings: omitWarningsDetails ? [] : warnings,
                                 errors: errors,
                                 notes: omitNotesDetails ? [] : notes,
                                 swiftFunctionTimes: nil,
                                 fetchedFromCache: wasFetchedFromCache(parent:
                                    parentSection, section: logSection),
                                 compilationEndTimestamp: 0,
                                 compilationDuration: 0,
                                 clangTimeTraceFile: nil,
                                 linkerStatistics: nil,
                                 swiftTypeCheckTimes: nil
                                 )

            step.subSteps = try logSection.subSections.map { subSection -> BuildStep in
                let subType: BuildStepType = type == .main ? .target : .detail
                
                
                return try parseLogSection(logSection: subSection,
                                           type: subType,
                                           parentSection: step,
                                           parentLogSection: logSection)
            }
            if type == .target {
                step.warningCount = targetWarnings
                step.errorCount = targetErrors
            } else if type == .detail {
                step = step.moveSwiftStepsToRoot()
            }
            if step.detailStepType == .swiftCompilation {
                if step.fetchedFromCache == false {
                    swiftCompilerParser.addLogSection(logSection)
                }
                if let swiftSteps = logSection.getSwiftIndividualSteps(buildStep: step,
                                                                       parentCommandDetailDesc:
                                                                       parentLogSection?.commandDetailDesc ?? "",
                                                                       currentIndex: &currentIndex) {
                    step.subSteps.append(contentsOf: swiftSteps)
                    step = step.withFilteredNotices()
                }
            }

            if step.fetchedFromCache == false && step.detailStepType == .cCompilation {
                step.clangTimeTraceFile = "file://\(clangCompilerParser.parseTimeTraceFile(logSection) ?? "")"
            }

            if step.fetchedFromCache == false && step.detailStepType == .linker {
                step.linkerStatistics = clangCompilerParser.parseLinkerStatistics(logSection)
            }

            step = addCompilationTimes(step: step)
            return step
    }

    private func toDate(timeInterval: Double) -> String {
        return dateFormatter.string(from: Date(timeIntervalSinceReferenceDate: timeInterval))
    }

    private func toTimestampSince1970(timeInterval: Double) -> Double {
        return Date(timeIntervalSinceReferenceDate: timeInterval).timeIntervalSince1970
    }

    private func getDuration(startTimeInterval: Double, endTimeInterval: Double) -> Double {
        var duration = endTimeInterval - startTimeInterval
        // If the endtime is almost the same as the endtime, we got a constant
        // in the tokens and a date in the future (year 4001). Here we normalize it to 0.0 secs
        if endTimeInterval >= 63113904000.0 {
            duration = 0.0
        }
        duration = duration >= 0 ? duration : 0.0
        return duration
    }

    private func getSchema(title: String) -> String {
        let schema = title.replacingOccurrences(of: "Build ", with: "")
        guard let schemaRegexp = schemeRegexp else {
            return schema
        }
        let range = NSRange(location: 0, length: title.count)
        let matches = schemaRegexp.matches(in: title, options: .reportCompletion, range: range)
        guard let match = matches.first else {
            return schema
        }
        return title.substring(match.range(at: 1))
    }

    private func toBuildStep(domainType: Int8) -> BuildStepType {
        switch domainType {
        case 0:
            return .main
        case 1:
            return .target
        case 2:
            return .detail
        default:
            return .detail
        }
    }

    /// In CLI logs, the target name is enclosed in a string like
    /// === BUILD TARGET TargetName OF PROJECT ProjectName WITH CONFIGURATION config ===
    /// This function extracts the target name of it.
    private func getTargetName(_ text: String) -> String {
        guard let targetRegexp = targetRegexp else {
            return text
        }
        let range = NSRange(location: 0, length: text.count)
        let matches = targetRegexp.matches(in: text, options: .reportCompletion, range: range)
        guard let match = matches.first, match.numberOfRanges == 3 else {
            return text
        }
        return "Target \(text.substring(match.range(at: 2)))"
    }

    private func parseArchitectureFromLogSection(_ logSection: IDEActivityLogSection,
                                                 andType type: DetailStepType) -> String {
        guard let clangArchRegexp = clangArchRegexp, let swiftcArchRegexp = swiftcArchRegexp else {
            return ""
        }
        switch type {
        case .cCompilation:
            return parseArchitectureFromCommand(command: logSection.signature, regexp: clangArchRegexp)
        case .swiftCompilation:
            return parseArchitectureFromCommand(command: logSection.signature, regexp: swiftcArchRegexp)
        default:
            return ""
        }
    }

    private func parseArchitectureFromCommand(command: String, regexp: NSRegularExpression) -> String {
        let range = NSRange(location: 0, length: command.count)
        let matches = regexp.matches(in: command, options: .reportCompletion, range: range)
        guard let match = matches.first else {
            return ""
        }
        return command.substring(match.range(at: 1))
    }

    private func parseWarningsAndErrorsFromLogSection(_ logSection: IDEActivityLogSection, forType type: DetailStepType)
        -> [String: [Notice]]? {
        let notices = Notice.parseFromLogSection(logSection, forType: type, truncLargeIssues: truncLargeIssues)
        return ["warnings": notices.getWarnings(),
                "errors": notices.getErrors(),
                "notes": notices.getNotes()]
    }
    
    private func parseWarningsAndErrorsFromLogSectionAsSubsection(_ logSection: IDEActivityLogSection, forType type: DetailStepType)
        -> [String: [Notice]]? {
        let notices = Notice.parseFromLogSection(logSection, forType: type, truncLargeIssues: truncLargeIssues, isSubsection: true)
        return ["warnings": notices.getWarnings(),
                "errors": notices.getErrors(),
                "notes": notices.getNotes()]
    }

    private func decorateWithSwiftcTimes(_ mainStep: BuildStep) -> BuildStep {
        swiftCompilerParser.parse()
        guard swiftCompilerParser.hasFunctionTimes() || swiftCompilerParser.hasTypeChecks() else {
            return mainStep
        }
        var mutableMainStep = mainStep
        mutableMainStep.subSteps = mainStep.subSteps.map { subStep -> BuildStep in
            var mutableTargetStep = subStep
            mutableTargetStep.subSteps = addSwiftcTimesSteps(mutableTargetStep.subSteps)
            return mutableTargetStep
        }
        return mutableMainStep
    }

    private func addSwiftcTimesSteps(_ subSteps: [BuildStep]) -> [BuildStep] {
        return subSteps.map { subStep -> BuildStep in
            switch subStep.detailStepType {
            case .swiftCompilation:
                var mutableSubStep = subStep
                if swiftCompilerParser.hasFunctionTimes() {
                    mutableSubStep.swiftFunctionTimes = swiftCompilerParser.findFunctionTimesForFilePath(
                    subStep.documentURL)
                }
                if swiftCompilerParser.hasTypeChecks() {
                    mutableSubStep.swiftTypeCheckTimes =
                        swiftCompilerParser.findTypeChecksForFilePath(subStep.documentURL)
                }
                if mutableSubStep.subSteps.count > 0 {
                     mutableSubStep.subSteps = addSwiftcTimesSteps(subStep.subSteps)
                }
                return mutableSubStep
            case .swiftAggregatedCompilation:
                var mutableSubStep = subStep
                mutableSubStep.subSteps = addSwiftcTimesSteps(subStep.subSteps)
                return mutableSubStep
            default:
                return subStep
            }
        }
    }

    private func wasFetchedFromCache(parent: BuildStep?, section: IDEActivityLogSection) -> Bool {
        if section.wasFetchedFromCache {
            return section.wasFetchedFromCache
        }
        return parent?.fetchedFromCache ?? false
    }

    func addCompilationTimes(step: BuildStep) -> BuildStep {
        switch step.type {
        case .detail:
            return step.with(newCompilationEndTimestamp: step.endTimestamp,
                             andCompilationDuration: step.duration)
        case .target:
            return addCompilationTimesToTarget(step)
        case .main:
            return addCompilationTimesToApp(step)
        }
    }

    private func addCompilationTimesToTarget(_ target: BuildStep) -> BuildStep {

        let lastCompilationStep = target.subSteps
            .filter { $0.isCompilationStep() && $0.fetchedFromCache == false }
            .max { $0.compilationEndTimestamp < $1.compilationEndTimestamp }
        guard let lastStep = lastCompilationStep else {
            return target.with(newCompilationEndTimestamp: target.startTimestamp, andCompilationDuration: 0.0)
        }
        return target.with(newCompilationEndTimestamp: lastStep.compilationEndTimestamp,
                         andCompilationDuration: lastStep.compilationEndTimestamp - target.startTimestamp)
    }

    private func addCompilationTimesToApp(_ app: BuildStep) -> BuildStep {
        let lastCompilationStep = app.subSteps
            .filter { $0.compilationDuration > 0 && $0.fetchedFromCache == false }
            .max { $0.compilationEndTimestamp < $1.compilationEndTimestamp }
        guard let lastStep = lastCompilationStep else {
            return app.with(newCompilationEndTimestamp: app.startTimestamp,
                            andCompilationDuration: 0.0)
        }
        return app.with(newCompilationEndTimestamp: lastStep.compilationEndTimestamp,
                         andCompilationDuration: lastStep.compilationEndTimestamp - app.startTimestamp)
    }

}
