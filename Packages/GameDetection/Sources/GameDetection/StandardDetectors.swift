/// The fixed precedence every import uses: refusals first, then families, then the web fallback; analyzers after.
public extension DetectionPipeline {
    static var standard: DetectionPipeline {
        DetectionPipeline(
            detectors: [
                RefusalDetectors(), RGSSDetector(), RenPyDetector(), RPGMakerMVMZDetector(), MVMZPluginScanner(),
                RM2kDetector(), GodotPCKDetector(), WebEngineDetector(),
            ],
            analyzers: [RuntimeBucketClassifier(), MediaRequirementAnalyzer(), SaveStrategyAnalyzer()]
        )
    }
}
