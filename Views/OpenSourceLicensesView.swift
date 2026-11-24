import SwiftUI

/// Displays app version information and full open-source attribution notices required by
/// Apache 2.0 and MIT licenses for on-device speech and EPUB dependencies.
struct OpenSourceLicensesView: View {
    private struct LicenseNotice: Identifiable {
        let id = UUID()
        let name: String
        let license: String
        let copyright: String
        let summary: String
        let licenseText: String
    }

    private let notices: [LicenseNotice] = [
        LicenseNotice(
            name: "Kokoro-82M",
            license: "Apache License 2.0",
            copyright: "Copyright © hexgrad / Kokoro-82M Contributors",
            summary: "82-million-parameter neural text-to-speech model running fully on-device via Apple CoreML and Neural Engine.",
            licenseText: """
            Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at:

            http://www.apache.org/licenses/LICENSE-2.0

            Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
            """
        ),
        LicenseNotice(
            name: "FluidAudio",
            license: "Apache License 2.0",
            copyright: "Copyright © Fluid Inference",
            summary: "Swift CoreML and Apple Neural Engine runtime for on-device Kokoro-82M speech synthesis and phonemization.",
            licenseText: """
            Licensed under the Apache License, Version 2.0 (the "License"); you may not use this software except in compliance with the License. You may obtain a copy of the License at:

            http://www.apache.org/licenses/LICENSE-2.0

            Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
            """
        ),
        LicenseNotice(
            name: "ZIPFoundation",
            license: "MIT License",
            copyright: "Copyright © 2017–2026 Thomas Zoechling",
            summary: "Streaming ZIP archive extraction library used to safely inspect and unpack EPUB containers.",
            licenseText: """
            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """
        )
    ]

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EPUB Audiobook Player")
                        .font(.headline)
                    Text(appVersionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("All narration synthesis, EPUB parsing, and audio caching run privately on your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            } header: {
                Text("About")
            }

            Section {
                ForEach(notices) { notice in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice.copyright)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(notice.licenseText)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 6)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(notice.name)
                                    .font(.body.weight(.semibold))
                                Spacer()
                                Text(notice.license)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(notice.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Open-Source Licenses")
            }
        }
        .navigationTitle("About & Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
