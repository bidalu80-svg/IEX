from pathlib import Path
root = Path(__file__).resolve().parents[1]
checks = 0

def text(path):
    return (root / path).read_text(encoding='utf-8-sig')

def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1
    print('PASS:', message)

store = text('Shared/MediaFavoritesStore.swift')
view = text('Views/Settings/MediaFavoritesView.swift')
content = text('Views/ContentView.swift')
media = text('Views/Chat/ZeMediaViews.swift')
input_bar = text('Views/Chat/ChatInputBar.swift')
gallery = text('Views/Chat/Media/MessageImageGallery.swift')
image_preview = text('Views/Chat/Media/ImagePreview.swift')
video_preview = text('Views/Chat/Media/VideoPlayer.swift')
audio_preview = text('Views/Chat/Media/AudioPreview.swift')
project = text('Ze.xcodeproj/project.pbxproj')

check('final class MediaFavoritesStore' in store and 'favorites/media' in store, 'persistent favorites store has durable media library')
check('FavoriteMediaKind' in store and all(x in store for x in ['case image', 'case video', 'case audio']), 'favorites are categorized as image/video/audio')
check('func remove(ids: Set<UUID>)' in store and 'makeStoredZip' in store, 'single/multi delete and ZIP archive are implemented')
check('MediaFavoritesView()' in content and 'case favorites' in content, 'Storage settings exposes the 收藏夹 destination')
check('LazyVGrid' in view and 'selectedIDs' in view and 'ZeShareSheet' in view, 'favorites view provides thumbnails, multi-select, delete and share')
check('收藏到收藏夹' in media and '收藏到收藏夹' in input_bar, 'chat media tiles and draft media expose long-press favorite')
check('onFavorite' in gallery and 'onFavorite' in image_preview, 'image preview/gallery expose favorite without removing copy/save')
check('MediaFavoritesStore.shared.add' in video_preview and 'MediaFavoritesStore.shared.add' in audio_preview, 'video/audio previews expose favorite action')
check('Shared/MediaFavoritesStore.swift' in project and 'Views/Settings/MediaFavoritesView.swift' in project, 'new files are in the Xcode project')
check(project.count('C0DEFA000000000000000001 /* MediaFavoritesStore.swift in Sources */') == 2 and project.count('C0DEFA000000000000000003 /* MediaFavoritesView.swift in Sources */') == 2, 'new files are in the app source phase')
check('ContentUnavailableView(' not in view and 'private var emptyLibraryView: some View' in view,
      'favorites empty state uses iOS 16-compatible views')
workflow = text('.github/workflows/build.yml')
check('2>&1 | tee build.log' in workflow and 'Summarize compiler errors' in workflow,
      'CI captures stderr and exposes compiler errors in the run summary')
print(f'Structural checks passed: {checks}')
