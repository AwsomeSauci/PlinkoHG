[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$DefoldJar,
    [string]$JavaPath
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$projectPath = (Resolve-Path -LiteralPath $ProjectRoot).Path
$jarPath = (Resolve-Path -LiteralPath $DefoldJar).Path
if (-not (Test-Path -LiteralPath (Join-Path $projectPath 'game.project') -PathType Leaf)) {
    throw "game.project was not found in $projectPath"
}

if (-not $JavaPath) {
    # Defold keeps its matching Java runtime next to the editor JAR.
    $runtimeDirectory = Get-ChildItem -LiteralPath (Split-Path -Parent $jarPath) -Directory |
        Where-Object { $_.Name -like 'jdk-*' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($runtimeDirectory) {
        $JavaPath = Join-Path $runtimeDirectory.FullName 'bin\java.exe'
    } else {
        $javaCommand = Get-Command java -ErrorAction SilentlyContinue
        if (-not $javaCommand) { throw 'Pass -JavaPath for the Java runtime matching this Defold JAR.' }
        $JavaPath = $javaCommand.Source
    }
}
$javaExecutable = (Resolve-Path -LiteralPath $JavaPath).Path

# This runs a text/schema inspector. It does not invoke Bob, compile assets,
# load the project in the engine, execute gameplay modules, or run test cases.
$inspector = @'
(do
(require '[clojure.java.io :as io] '[clojure.string :as str])
(import '[com.google.protobuf TextFormat Message]
        '[com.dynamo.proto DdfExtensions]
        '[java.nio.file Files LinkOption]
        '[java.util.jar JarFile])

(def schemas
  {".collection" "com.dynamo.gameobject.proto.GameObject$CollectionDesc"
   ".go" "com.dynamo.gameobject.proto.GameObject$PrototypeDesc"
   ".gui" "com.dynamo.gamesys.proto.Gui$SceneDesc"
   ".render" "com.dynamo.render.proto.Render$RenderPrototypeDesc"
   ".mesh" "com.dynamo.gamesys.proto.MeshProto$MeshDesc"
   ".material" "com.dynamo.render.proto.Material$MaterialDesc"
   ".sound" "com.dynamo.gamesys.proto.Sound$SoundDesc"
   ".font" "com.dynamo.render.proto.Font$FontDesc"
   ".input_binding" "com.dynamo.input.proto.Input$InputBinding"})
(def ignored-directories
  #{".git" ".internal" ".idea" ".vscode" "build" "builtins" "bundle" "bundles" ".local"})
(def root (.toRealPath (.toPath (io/file (System/getenv "PLINKO_RESOURCE_ROOT"))) (make-array LinkOption 0)))
(def errors (atom []))
(def parsed-count (atom 0))
(def reference-count (atom 0))
(defn fail! [owner detail] (swap! errors conj (str owner ": " detail)))
(defn extension [path] (or (re-find #"\.[^./\\]+$" path) ""))
(defn source-files [directory]
  (mapcat
    (fn [file]
      (cond
        (Files/isSymbolicLink (.toPath file)) []
        (.isDirectory file) (if (ignored-directories (.getName file)) [] (source-files file))
        (contains? schemas (extension (.getName file))) [file]
        :else []))
    (sort-by #(.getName %) (or (.listFiles directory) []))))

(def compiled-suffixes
  (merge (into {} (map (fn [suffix] [(str suffix "c") suffix]) (keys schemas)))
         {".scriptc" ".script" ".gui_scriptc" ".gui_script"
          ".render_scriptc" ".render_script" ".display_profilesc" ".display_profiles"
          ".texture_profilesc" ".texture_profiles" ".gamepadsc" ".gamepads"}))
(defn source-path [path]
  (if-let [suffix (compiled-suffixes (extension path))]
    (str (subs path 0 (- (count path) (count (extension path)))) suffix)
    path))

(defn check-reference! [jar owner path]
  (when (and (string? path) (not (str/blank? path)))
    (swap! reference-count inc)
    (cond
      (not (str/starts-with? path "/")) (fail! owner (str "resource must be project-absolute: " path))
      (str/includes? path "\\") (fail! owner (str "resource must use forward slashes: " path))
      :else
      (let [candidate (source-path path)
            relative (subs candidate 1)]
        (if (str/starts-with? candidate "/builtins/")
          (when (nil? (.getJarEntry jar relative))
            (fail! owner (str "missing built-in resource: " path)))
          (let [resolved (.normalize (.resolve root relative))]
            (cond
              (not (.startsWith resolved root)) (fail! owner (str "resource escapes project: " path))
              (not (Files/isRegularFile resolved (make-array LinkOption 0))) (fail! owner (str "missing resource: " path))
              (not (.startsWith (.toRealPath resolved (make-array LinkOption 0)) root))
              (fail! owner (str "resource symlink escapes project: " path)))))))))

(declare inspect-message!)
(defn parse-message! [jar owner text class-name]
  (let [message-class (Class/forName class-name)
        builder (.invoke (.getMethod message-class "newBuilder" (make-array Class 0)) nil (object-array 0))]
    (TextFormat/merge text builder)
    (let [message (.build builder)]
      (inspect-message! jar owner message)
      message)))

(defn inspect-message! [jar owner message]
  (doseq [[field value] (.getAllFields message)
          entry (if (.isRepeated field) value [value])]
    (cond
      (instance? Message entry) (inspect-message! jar owner entry)
      (.getExtension (.getOptions field) DdfExtensions/resource)
      (check-reference! jar (str owner " [" (.getName field) "]") entry)))
  ;; Embedded resources are strings in the outer schema; inspect supported
  ;; embedded component types and embedded game object prototypes explicitly.
  (let [descriptor (.getDescriptorForType message)
        kind (.getName descriptor)]
    (when (contains? #{"EmbeddedComponentDesc" "EmbeddedInstanceDesc"} kind)
      (let [data-field (.findFieldByName descriptor "data")
            type-field (.findFieldByName descriptor "type")
            resource-type (if type-field (.getField message type-field) "go")
            schema (schemas (str "." resource-type))]
        (when (and schema data-field)
          (parse-message! jar (str owner " [embedded " resource-type "]")
                          (.getField message data-field) schema))))))

(defn inspect-project! [jar]
  (loop [section "" lines (str/split-lines (slurp (str (.resolve root "game.project")) :encoding "UTF-8"))]
    (when-let [line (first lines)]
      (let [trimmed (str/trim line)]
        (cond
          (re-matches #"\[([^\]]+)\]" trimmed)
          (recur (second (re-matches #"\[([^\]]+)\]" trimmed)) (rest lines))
          (or (str/starts-with? trimmed "#") (str/starts-with? trimmed ";"))
          (recur section (rest lines))
          :else
          (do
            (when-let [[match key value] (re-matches #"([^=]+?)\s*=\s*(.*?)\s*" trimmed)]
              ;; Project resource settings use project-absolute paths. Ordinary
              ;; project values are intentionally not interpreted as resources.
              (when (str/starts-with? value "/")
                (doseq [path (str/split value #"\s*,\s*")]
                  (check-reference! jar (str "game.project [" section "." (str/trim key) "]") path))))
            (recur section (rest lines))))))))

(with-open [jar (JarFile. (System/getenv "PLINKO_DEFOLD_JAR"))]
  (doseq [file (source-files (.toFile root))]
    (let [owner (str (.relativize root (.toPath file)))]
      (try
        (parse-message! jar owner (slurp file :encoding "UTF-8") (schemas (extension (.getName file))))
        (swap! parsed-count inc)
        (println "PARSED" owner)
        (catch Throwable error (fail! owner (.getMessage error))))))
  (try (inspect-project! jar)
       (catch Throwable error (fail! "game.project" (.getMessage error)))))
(doseq [error @errors] (println "ERROR" error))
(println (format "Static resources: %d parsed, %d references inspected, %d errors."
                 @parsed-count @reference-count (count @errors)))
(shutdown-agents)
(System/exit (if (empty? @errors) 0 1)))
'@

$previousProject = [Environment]::GetEnvironmentVariable('PLINKO_RESOURCE_ROOT', 'Process')
$previousJar = [Environment]::GetEnvironmentVariable('PLINKO_DEFOLD_JAR', 'Process')
try {
    $env:PLINKO_RESOURCE_ROOT = $projectPath
    $env:PLINKO_DEFOLD_JAR = $jarPath
    # A source file avoids Windows PowerShell 5.1 stripping quotes from a
    # multiline native command argument. No gameplay/resource compiler runs.
    $inspectionDirectory = Join-Path $projectPath '.internal'
    New-Item -ItemType Directory -Path $inspectionDirectory -Force | Out-Null
    $inspectionPath = Join-Path $inspectionDirectory 'resource-inspection.clj'
    [System.IO.File]::WriteAllText($inspectionPath, $inspector, (New-Object System.Text.UTF8Encoding $false))
    & $javaExecutable -cp $jarPath clojure.main $inspectionPath
    if ($LASTEXITCODE -ne 0) {
        throw "Static resource inspection failed (exit $LASTEXITCODE)."
    }
} finally {
    [Environment]::SetEnvironmentVariable('PLINKO_RESOURCE_ROOT', $previousProject, 'Process')
    [Environment]::SetEnvironmentVariable('PLINKO_DEFOLD_JAR', $previousJar, 'Process')
}
