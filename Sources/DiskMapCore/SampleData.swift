import Foundation

public enum SampleData {
    /// Entirely synthetic data. No paths below are read from disk.
    public static let root: FileNode = folder("sample", "나의 Mac", "/샘플", .projects, [
        folder("projects", "프로젝트", "/샘플/프로젝트", .projects, [
            folder("unity", "Unity 프로젝트", "/샘플/프로젝트/Unity 프로젝트", .projects, [
                file("unity-build", "Game Build.zip", "/샘플/프로젝트/Unity 프로젝트/Game Build.zip", 18.6, .projects),
                file("unity-library", "Library 아카이브.zip", "/샘플/프로젝트/Unity 프로젝트/Library 아카이브.zip", 12.8, .projects),
                file("unity-assets", "Assets 백업.zip", "/샘플/프로젝트/Unity 프로젝트/Assets 백업.zip", 8.4, .projects),
            ]),
            folder("design", "디자인 작업", "/샘플/프로젝트/디자인 작업", .projects, [
                file("design-mockup", "브랜드 목업.psd", "/샘플/프로젝트/디자인 작업/브랜드 목업.psd", 6.3, .projects),
                file("design-export", "에셋 모음.zip", "/샘플/프로젝트/디자인 작업/에셋 모음.zip", 4.5, .projects),
            ]),
        ]),
        folder("downloads", "다운로드", "/샘플/다운로드", .downloads, [
            file("download-installer", "설치 이미지.dmg", "/샘플/다운로드/설치 이미지.dmg", 9.2, .downloads),
            file("download-video", "강의 자료.zip", "/샘플/다운로드/강의 자료.zip", 5.8, .downloads),
            folder("download-old", "이전 다운로드", "/샘플/다운로드/이전 다운로드", .downloads, [
                file("download-old-archive", "백업 자료.zip", "/샘플/다운로드/이전 다운로드/백업 자료.zip", 4.1, .downloads),
                file("download-old-pdf", "레퍼런스.pdf", "/샘플/다운로드/이전 다운로드/레퍼런스.pdf", 0.25, .documents),
            ]),
        ]),
        folder("movies", "동영상", "/샘플/동영상", .movies, [
            file("movie-travel", "여행 영상.mov", "/샘플/동영상/여행 영상.mov", 11.6, .movies),
            file("movie-recording", "화면 녹화.mov", "/샘플/동영상/화면 녹화.mov", 6.4, .movies),
        ]),
        folder("pictures", "사진", "/샘플/사진", .pictures, [
            file("picture-raw", "촬영 원본.zip", "/샘플/사진/촬영 원본.zip", 7.2, .pictures),
            file("picture-export", "편집본.zip", "/샘플/사진/편집본.zip", 2.1, .pictures),
        ]),
        folder("documents", "문서", "/샘플/문서", .documents, [
            file("document-notes", "작업 노트.pdf", "/샘플/문서/작업 노트.pdf", 0.18, .documents),
            file("document-reference", "참고 자료.zip", "/샘플/문서/참고 자료.zip", 1.4, .documents),
            folder("empty", "빈 폴더", "/샘플/문서/빈 폴더", .documents, []),
        ]),
    ])

    private static func folder(
        _ id: String, _ name: String, _ path: String, _ category: FileCategory, _ children: [FileNode]
    ) -> FileNode {
        FileNode(id: id, name: name, path: path, kind: .folder, children: children, category: category)
    }

    private static func file(
        _ id: String, _ name: String, _ path: String, _ gb: Double, _ category: FileCategory
    ) -> FileNode {
        FileNode(id: id, name: name, path: path, kind: .file,
                 fileBytes: Int64((gb * 1_000_000_000).rounded()), category: category)
    }
}
