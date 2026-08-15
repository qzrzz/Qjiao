import type { II18nConfig } from "qpage";

const i18n: II18nConfig = {
  defaultLang: "zh-Hans",
  langs: {
    "zh-Hans": {
      name: "简体中文",
      page: {
        tagline:
          "面向新手的终端工作区，集终端、Agent、文件管理、代码编辑与运行、Git、图片处理等功能于一体，原生、免费、开源。",
        taglineShort: "终端工作区",
        metaDesc:
          "面向 macOS 的原生、免费、开源终端工作区，集成 AI Agent、文件管理、代码编辑与运行、Git、图片处理等功能。",
      },
      ui: {
        download: "下载",
        viewOnGithub: "GitHub",
        langSwitchAria: "选择语言",
        otherProducts: "其他产品",
        moreProducts: "更多产品",
        productLinks: "产品",
        contact: "联络",
        officialWebsite: "官网",
        docs: "文档",
        changelog: "更新记录",
      },
    },

    en: {
      name: "English",
      page: {
        tagline:
          "A beginner-friendly terminal workspace for terminal sessions, AI agents, file management, code editing and running, Git, image processing, and more — native, free, and open source.",
        taglineShort: "Terminal workspace",
        metaDesc:
          "A native, free, open-source terminal workspace for macOS with AI agents, file management, code editing and running, Git, image processing, and more.",
      },
      ui: {
        download: "Download",
        viewOnGithub: "View on GitHub",
        langSwitchAria: "Select language",
        otherProducts: "Other products",
        moreProducts: "More products",
        productLinks: "Product",
        contact: "Contact",
        officialWebsite: "Website",
        docs: "Documentation",
        changelog: "Changelog",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Move the cursor freely",
              desc: "Move and edit naturally, just like in a text editor.",
            },
          ],
        },
        {
          id: "projects",
          title: "A workspace built around your projects",
          description:
            "Get everything done without leaving your terminal workspace — CLI, AI agents, file management, and Git.",
          cards: [
            {
              id: "agent",
              title: "Work with multiple AI agents in parallel",
              desc: "Use multiple tabs and panes to let several AI agents work together.",
            },
            {
              id: "project",
              title: "Project identification",
              desc: "Distinguish projects at a glance with custom icons, names, descriptions, and color themes.",
            },
            {
              id: "files",
              title: "File management",
              desc: "Manage files right next to your terminal, with type icons, file sizes, keyboard navigation, image previews, and Spacebar Quick Look.",
            },
            {
              id: "scripts-tasks",
              title: "Scripts & tasks",
              desc: "Run NPM Scripts, Gradle Tasks, Cargo, and CMake commands visually with one click.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Visualize common Git operations and generate commit messages with one click.\nPowered by a local Agent CLI, with no API key required.",
            },
            {
              id: "launchers",
              title: "Quick launchers",
              desc: "Start the tools your project needs quickly.\nLaunch apps, docs, terminals, or open folders with one click.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "A better experience for web development",
          description: "Building a web project? You’ll love these features.",
          cards: [
            {
              id: "package-manager",
              title: "Package manager integration",
              desc: "Quickly edit dependency versions, detect NPM Scripts, and discover development server ports.",
            },
            {
              id: "dev-server",
              title: "Development server detection",
              desc: "Know where your services are running at a glance.\nPorts and preview links, all in one place.",
            },
            {
              id: "code-formatting",
              title: "Code formatting",
              desc: "Built-in support for formatting code with oxfmt and Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Run TS, JS, Python, Go, and Rust files with one click.",
            },
            {
              id: "image-viewer",
              title: "Powerful image viewer",
              desc: "A full-featured image viewer with metadata, rulers, pixel inspection, comparison mode, and more.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Compress, resize, and convert images with design-tool-grade export controls.",
            },
          ],
        },
      ],
    },

    ja: {
      name: "日本語",
      page: {
        tagline:
          "ターミナル、AIエージェント、ファイル管理、コードの編集・実行、Git、画像処理などを一つにまとめた、初心者にも使いやすいネイティブで無料のオープンソース・ターミナルワークスペース。",
        taglineShort: "ターミナルワークスペース",
        metaDesc:
          "AIエージェント、ファイル管理、コードの編集・実行、Git、画像処理などを備えた、macOS向けのネイティブで無料のオープンソース・ターミナルワークスペース。",
      },
      ui: {
        download: "ダウンロード",
        viewOnGithub: "GitHubで見る",
        langSwitchAria: "言語を選択",
        otherProducts: "その他の製品",
        moreProducts: "すべての製品",
        productLinks: "製品",
        contact: "お問い合わせ",
        officialWebsite: "公式サイト",
        docs: "ドキュメント",
        changelog: "変更履歴",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "カーソルを自由に動かす",
              desc: "テキストエディタのように自然に移動・編集できます。",
            },
          ],
        },
        {
          id: "projects",
          title: "プロジェクトを中心に効率よく作業",
          description:
            "ターミナルワークスペースを離れることなく、CLI、AIエージェント、ファイル管理、Gitまで完結できます。",
          cards: [
            {
              id: "agent",
              title: "複数のAIエージェントを並列実行",
              desc: "複数のタブとペインで、複数のAIエージェントを連携させて作業できます。",
            },
            {
              id: "project",
              title: "プロジェクトをひと目で識別",
              desc: "カスタムアイコン、名称、説明、カラーテーマで複数のプロジェクトを明確に区別できます。",
            },
            {
              id: "files",
              title: "ファイル管理",
              desc: "ターミナルの隣でファイルを管理。種類別アイコン、ファイルサイズ、キーボード操作、画像プレビュー、スペースキーのQuick Lookに対応します。",
            },
            {
              id: "scripts-tasks",
              title: "スクリプトとタスク",
              desc: "NPM Scripts、Gradle Tasks、Cargo、CMakeのコマンドを可視化し、ワンクリックで実行できます。",
            },
            {
              id: "git",
              title: "Git",
              desc: "よく使うGit操作を可視化し、コミットメッセージをワンクリックで生成できます。\nローカルのAgent CLIで動作するため、APIキーは不要です。",
            },
            {
              id: "launchers",
              title: "クイックランチャー",
              desc: "プロジェクトに必要なツールをすばやく起動。\nアプリ、ドキュメント、ターミナルを起動したり、フォルダをワンクリックで開けます。",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Web開発をもっと快適に",
          description: "Webプロジェクトを開発中ですか？きっと気に入る機能が揃っています。",
          cards: [
            {
              id: "package-manager",
              title: "パッケージマネージャー連携",
              desc: "依存関係のバージョン変更、NPM Scriptsの自動検出、開発サーバーのポート確認などをすばやく行えます。",
            },
            {
              id: "dev-server",
              title: "開発サーバーのポート検出",
              desc: "サービスの稼働状況をいつでも把握。\nポートとプレビューリンクをひと目で確認できます。",
            },
            {
              id: "code-formatting",
              title: "コードフォーマット",
              desc: "oxfmtとPrettierによるコード整形を標準サポートします。",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "TS、JS、Python、Go、Rustのコードファイルをワンクリックで実行できます。",
            },
            {
              id: "image-viewer",
              title: "高機能画像ビューア",
              desc: "メタデータ、ルーラー、ピクセル検査、比較モードなどに対応したフル機能の画像ビューアを内蔵しています。",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "デザインツール級の書き出し機能で、画像の圧縮、サイズ変更、形式変換を行えます。",
            },
          ],
        },
      ],
    },

    ko: {
      name: "한국어",
      page: {
        tagline:
          "터미널, AI 에이전트, 파일 관리, 코드 편집 및 실행, Git, 이미지 처리 등을 한곳에 담은 초보자 친화적인 네이티브 무료 오픈 소스 터미널 워크스페이스.",
        taglineShort: "터미널 워크스페이스",
        metaDesc:
          "AI 에이전트, 파일 관리, 코드 편집 및 실행, Git, 이미지 처리 등을 제공하는 macOS용 네이티브 무료 오픈 소스 터미널 워크스페이스입니다.",
      },
      ui: {
        download: "다운로드",
        viewOnGithub: "GitHub에서 보기",
        langSwitchAria: "언어 선택",
        otherProducts: "기타 제품",
        moreProducts: "더 많은 제품",
        productLinks: "제품",
        contact: "문의",
        officialWebsite: "웹사이트",
        docs: "문서",
        changelog: "변경 기록",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "자유로운 커서 이동",
              desc: "텍스트 편집기처럼 자연스럽게 이동하고 편집하세요.",
            },
          ],
        },
        {
          id: "projects",
          title: "프로젝트 중심의 효율적인 작업",
          description:
            "터미널 워크스페이스를 벗어나지 않고 CLI, AI 에이전트, 파일 관리, Git 작업을 모두 처리하세요.",
          cards: [
            {
              id: "agent",
              title: "여러 AI 에이전트 병렬 작업",
              desc: "여러 탭과 패널에서 여러 AI 에이전트가 함께 작업할 수 있습니다.",
            },
            {
              id: "project",
              title: "프로젝트 식별",
              desc: "사용자 지정 아이콘, 이름, 설명과 색상 테마로 여러 프로젝트를 한눈에 구분하세요.",
            },
            {
              id: "files",
              title: "파일 관리",
              desc: "터미널 옆에서 파일을 바로 관리하세요. 파일 형식 아이콘, 크기, 키보드 탐색, 이미지 미리보기, 스페이스바 Quick Look을 지원합니다.",
            },
            {
              id: "scripts-tasks",
              title: "스크립트 및 작업",
              desc: "NPM Scripts, Gradle Tasks, Cargo, CMake 명령을 시각적으로 확인하고 한 번의 클릭으로 실행하세요.",
            },
            {
              id: "git",
              title: "Git",
              desc: "자주 쓰는 Git 작업을 시각화하고 커밋 메시지를 한 번의 클릭으로 생성하세요.\n로컬 Agent CLI로 구동되므로 API 키가 필요하지 않습니다.",
            },
            {
              id: "launchers",
              title: "빠른 실행 도구",
              desc: "프로젝트에 필요한 도구를 빠르게 시작하세요.\n앱, 문서, 터미널을 실행하거나 폴더를 한 번의 클릭으로 여세요.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "더 편리한 웹 개발 경험",
          description: "웹 프로젝트를 개발 중인가요? 이 기능들을 마음에 들어 하실 거예요.",
          cards: [
            {
              id: "package-manager",
              title: "패키지 관리자 통합",
              desc: "의존성 버전을 빠르게 수정하고, NPM Scripts와 개발 서버 포트를 자동으로 확인하세요.",
            },
            {
              id: "dev-server",
              title: "개발 서버 포트 감지",
              desc: "서비스가 실행 중인 위치를 항상 확인하세요.\n포트와 미리보기 링크를 한눈에 볼 수 있습니다.",
            },
            {
              id: "code-formatting",
              title: "코드 포맷팅",
              desc: "oxfmt와 Prettier를 사용한 코드 포맷팅을 기본 지원합니다.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "TS, JS, Python, Go, Rust 코드 파일을 한 번의 클릭으로 실행하세요.",
            },
            {
              id: "image-viewer",
              title: "강력한 이미지 뷰어",
              desc: "메타데이터, 눈금자, 픽셀 검사, 비교 모드 등을 지원하는 모든 기능을 갖춘 이미지 뷰어입니다.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "디자인 도구 수준의 내보내기 기능으로 이미지를 압축하고, 크기를 조정하고, 형식을 변환하세요.",
            },
          ],
        },
      ],
    },

    vi: {
      name: "Tiếng Việt",
      page: {
        tagline:
          "Không gian làm việc terminal thân thiện với người mới, tích hợp terminal, AI agent, quản lý tệp, chỉnh sửa và chạy mã, Git, xử lý hình ảnh cùng nhiều tính năng khác — bản địa, miễn phí và mã nguồn mở.",
        taglineShort: "Không gian làm việc terminal",
        metaDesc:
          "Không gian làm việc terminal gốc cho macOS, miễn phí và mã nguồn mở, tích hợp AI agent, quản lý tệp, chỉnh sửa và chạy mã, Git, xử lý hình ảnh cùng nhiều tính năng khác.",
      },
      ui: {
        download: "Tải xuống",
        viewOnGithub: "Xem trên GitHub",
        langSwitchAria: "Chọn ngôn ngữ",
        otherProducts: "Sản phẩm khác",
        moreProducts: "Xem thêm sản phẩm",
        productLinks: "Sản phẩm",
        contact: "Liên hệ",
        officialWebsite: "Trang web",
        docs: "Tài liệu",
        changelog: "Nhật ký thay đổi",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Di chuyển con trỏ tự do",
              desc: "Di chuyển và chỉnh sửa tự nhiên như trong trình soạn thảo văn bản.",
            },
          ],
        },
        {
          id: "projects",
          title: "Làm việc hiệu quả xoay quanh dự án",
          description:
            "Hoàn thành mọi việc mà không cần rời khỏi không gian làm việc terminal — CLI, AI agent, quản lý tệp và Git.",
          cards: [
            {
              id: "agent",
              title: "Làm việc song song với nhiều AI agent",
              desc: "Sử dụng nhiều tab và pane để các AI agent phối hợp làm việc.",
            },
            {
              id: "project",
              title: "Nhận diện dự án",
              desc: "Phân biệt các dự án ngay lập tức bằng biểu tượng, tên, mô tả và chủ đề màu tùy chỉnh.",
            },
            {
              id: "files",
              title: "Quản lý tệp",
              desc: "Quản lý tệp ngay bên cạnh terminal với biểu tượng loại tệp, kích thước, điều hướng bằng bàn phím, xem trước hình ảnh và Quick Look bằng phím cách.",
            },
            {
              id: "scripts-tasks",
              title: "Script và tác vụ",
              desc: "Trực quan hóa các lệnh NPM Scripts, Gradle Tasks, Cargo và CMake rồi chạy chúng chỉ bằng một cú nhấp.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Trực quan hóa các thao tác Git phổ biến và tạo thông điệp commit chỉ bằng một cú nhấp.\nĐược vận hành bởi Agent CLI cục bộ, không cần API key.",
            },
            {
              id: "launchers",
              title: "Trình khởi chạy nhanh",
              desc: "Nhanh chóng mở các công cụ cần cho dự án.\nKhởi chạy ứng dụng, tài liệu, terminal hoặc mở thư mục chỉ bằng một cú nhấp.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Trải nghiệm phát triển web tốt hơn",
          description: "Đang xây dựng một dự án web? Bạn sẽ yêu thích những tính năng này.",
          cards: [
            {
              id: "package-manager",
              title: "Tích hợp trình quản lý gói",
              desc: "Nhanh chóng chỉnh sửa phiên bản phụ thuộc, tự động phát hiện NPM Scripts và cổng của máy chủ phát triển.",
            },
            {
              id: "dev-server",
              title: "Phát hiện cổng máy chủ phát triển",
              desc: "Luôn biết dịch vụ đang chạy ở đâu.\nCổng và liên kết xem trước được hiển thị rõ ràng.",
            },
            {
              id: "code-formatting",
              title: "Định dạng mã",
              desc: "Tích hợp sẵn hỗ trợ định dạng mã bằng oxfmt và Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Chạy tệp mã TS, JS, Python, Go và Rust chỉ bằng một cú nhấp.",
            },
            {
              id: "image-viewer",
              title: "Trình xem hình ảnh mạnh mẽ",
              desc: "Trình xem hình ảnh đầy đủ tính năng với siêu dữ liệu, thước đo, kiểm tra pixel, chế độ so sánh và nhiều hơn nữa.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Nén, thay đổi kích thước và chuyển đổi định dạng hình ảnh với khả năng xuất ở cấp độ công cụ thiết kế.",
            },
          ],
        },
      ],
    },

    pt: {
      name: "Português",
      page: {
        tagline:
          "Um espaço de trabalho de terminal amigável para iniciantes, que reúne terminal, agentes de IA, gerenciamento de arquivos, edição e execução de código, Git, processamento de imagens e muito mais — nativo, gratuito e de código aberto.",
        taglineShort: "Espaço de trabalho de terminal",
        metaDesc:
          "Um espaço de trabalho de terminal nativo, gratuito e de código aberto para macOS, com agentes de IA, gerenciamento de arquivos, edição e execução de código, Git, processamento de imagens e muito mais.",
      },
      ui: {
        download: "Baixar",
        viewOnGithub: "Ver no GitHub",
        langSwitchAria: "Selecionar idioma",
        otherProducts: "Outros produtos",
        moreProducts: "Mais produtos",
        productLinks: "Produto",
        contact: "Contato",
        officialWebsite: "Site",
        docs: "Documentação",
        changelog: "Registro de alterações",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Mova o cursor livremente",
              desc: "Mova e edite com a mesma naturalidade de um editor de texto.",
            },
          ],
        },
        {
          id: "projects",
          title: "Um espaço de trabalho centrado nos seus projetos",
          description:
            "Faça tudo sem sair do espaço de trabalho do terminal — CLI, agentes de IA, gerenciamento de arquivos e Git.",
          cards: [
            {
              id: "agent",
              title: "Trabalhe com vários agentes de IA em paralelo",
              desc: "Use várias abas e painéis para que diversos agentes de IA trabalhem juntos.",
            },
            {
              id: "project",
              title: "Identificação de projetos",
              desc: "Diferencie seus projetos rapidamente com ícones, nomes, descrições e temas de cores personalizados.",
            },
            {
              id: "files",
              title: "Gerenciamento de arquivos",
              desc: "Gerencie arquivos ao lado do terminal, com ícones de tipo, tamanhos, navegação pelo teclado, prévias de imagens e Quick Look pela barra de espaço.",
            },
            {
              id: "scripts-tasks",
              title: "Scripts e tarefas",
              desc: "Visualize comandos NPM Scripts, Gradle Tasks, Cargo e CMake e execute-os com um clique.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Visualize operações comuns do Git e gere mensagens de commit com um clique.\nUsa o Agent CLI local, sem necessidade de API key.",
            },
            {
              id: "launchers",
              title: "Inicializadores rápidos",
              desc: "Inicie rapidamente as ferramentas do seu projeto.\nAbra aplicativos, documentos, terminais ou pastas com um clique.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Uma experiência melhor para desenvolvimento web",
          description: "Desenvolvendo um projeto web? Você vai gostar destes recursos.",
          cards: [
            {
              id: "package-manager",
              title: "Integração com gerenciadores de pacotes",
              desc: "Edite rapidamente versões de dependências, detecte NPM Scripts e descubra as portas dos servidores de desenvolvimento.",
            },
            {
              id: "dev-server",
              title: "Detecção de servidores de desenvolvimento",
              desc: "Saiba de imediato onde seus serviços estão rodando.\nPortas e links de pré-visualização em um só lugar.",
            },
            {
              id: "code-formatting",
              title: "Formatação de código",
              desc: "Suporte integrado à formatação de código com oxfmt e Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Execute arquivos TS, JS, Python, Go e Rust com um clique.",
            },
            {
              id: "image-viewer",
              title: "Visualizador de imagens completo",
              desc: "Um visualizador de imagens completo com metadados, réguas, inspeção de pixels, modo de comparação e muito mais.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Comprima, redimensione e converta imagens com controles de exportação no nível de ferramentas de design.",
            },
          ],
        },
      ],
    },

    es: {
      name: "Español",
      page: {
        tagline:
          "Un espacio de trabajo de terminal fácil de usar para principiantes que reúne terminal, agentes de IA, gestión de archivos, edición y ejecución de código, Git, procesamiento de imágenes y más — nativo, gratuito y de código abierto.",
        taglineShort: "Espacio de trabajo de terminal",
        metaDesc:
          "Un espacio de trabajo de terminal nativo, gratuito y de código abierto para macOS, con agentes de IA, gestión de archivos, edición y ejecución de código, Git, procesamiento de imágenes y más.",
      },
      ui: {
        download: "Descargar",
        viewOnGithub: "Ver en GitHub",
        langSwitchAria: "Seleccionar idioma",
        otherProducts: "Otros productos",
        moreProducts: "Más productos",
        productLinks: "Producto",
        contact: "Contacto",
        officialWebsite: "Sitio web",
        docs: "Documentación",
        changelog: "Registro de cambios",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Mueve el cursor libremente",
              desc: "Mueve y edita con la misma naturalidad que en un editor de texto.",
            },
          ],
        },
        {
          id: "projects",
          title: "Un espacio de trabajo centrado en tus proyectos",
          description:
            "Hazlo todo sin salir del espacio de trabajo de terminal — CLI, agentes de IA, gestión de archivos y Git.",
          cards: [
            {
              id: "agent",
              title: "Trabaja con varios agentes de IA en paralelo",
              desc: "Usa varias pestañas y paneles para que varios agentes de IA trabajen juntos.",
            },
            {
              id: "project",
              title: "Identificación de proyectos",
              desc: "Distingue tus proyectos de un vistazo con iconos, nombres, descripciones y temas de color personalizados.",
            },
            {
              id: "files",
              title: "Gestión de archivos",
              desc: "Gestiona archivos junto a tu terminal, con iconos de tipo, tamaños, navegación con teclado, vistas previas de imágenes y Quick Look con la barra espaciadora.",
            },
            {
              id: "scripts-tasks",
              title: "Scripts y tareas",
              desc: "Visualiza comandos de NPM Scripts, Gradle Tasks, Cargo y CMake, y ejecútalos con un clic.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Visualiza operaciones habituales de Git y genera mensajes de commit con un clic.\nFunciona con un Agent CLI local, sin necesidad de API key.",
            },
            {
              id: "launchers",
              title: "Lanzadores rápidos",
              desc: "Inicia rápidamente las herramientas que necesita tu proyecto.\nAbre aplicaciones, documentos, terminales o carpetas con un clic.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Una mejor experiencia para el desarrollo web",
          description: "¿Estás desarrollando un proyecto web? Te encantarán estas funciones.",
          cards: [
            {
              id: "package-manager",
              title: "Integración con gestores de paquetes",
              desc: "Edita rápidamente versiones de dependencias, detecta NPM Scripts y descubre los puertos de los servidores de desarrollo.",
            },
            {
              id: "dev-server",
              title: "Detección del servidor de desarrollo",
              desc: "Sabe siempre dónde se ejecutan tus servicios.\nPuertos y enlaces de vista previa, de un vistazo.",
            },
            {
              id: "code-formatting",
              title: "Formateo de código",
              desc: "Compatibilidad integrada con el formateo mediante oxfmt y Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Ejecuta archivos de código TS, JS, Python, Go y Rust con un clic.",
            },
            {
              id: "image-viewer",
              title: "Potente visor de imágenes",
              desc: "Un visor de imágenes completo con metadatos, reglas, inspección de píxeles, modo de comparación y mucho más.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Comprime, cambia el tamaño y convierte imágenes con controles de exportación al nivel de una herramienta de diseño.",
            },
          ],
        },
      ],
    },

    de: {
      name: "Deutsch",
      page: {
        tagline:
          "Eine einsteigerfreundliche Terminal-Arbeitsumgebung mit Terminal, KI-Agenten, Dateiverwaltung, Codebearbeitung und -ausführung, Git, Bildverarbeitung und mehr — nativ, kostenlos und Open Source.",
        taglineShort: "Terminal-Arbeitsumgebung",
        metaDesc:
          "Eine native, kostenlose und quelloffene Terminal-Arbeitsumgebung für macOS mit KI-Agenten, Dateiverwaltung, Codebearbeitung und -ausführung, Git, Bildverarbeitung und mehr.",
      },
      ui: {
        download: "Herunterladen",
        viewOnGithub: "Auf GitHub ansehen",
        langSwitchAria: "Sprache auswählen",
        otherProducts: "Weitere Produkte",
        moreProducts: "Mehr Produkte",
        productLinks: "Produkt",
        contact: "Kontakt",
        officialWebsite: "Website",
        docs: "Dokumentation",
        changelog: "Änderungsprotokoll",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Cursor frei bewegen",
              desc: "Bewege und bearbeite Inhalte so natürlich wie in einem Texteditor.",
            },
          ],
        },
        {
          id: "projects",
          title: "Eine Arbeitsumgebung rund um deine Projekte",
          description:
            "Erledige alles, ohne deine Terminal-Arbeitsumgebung zu verlassen — CLI, KI-Agenten, Dateiverwaltung und Git.",
          cards: [
            {
              id: "agent",
              title: "Mit mehreren KI-Agenten parallel arbeiten",
              desc: "Nutze mehrere Tabs und Bereiche, damit mehrere KI-Agenten zusammenarbeiten können.",
            },
            {
              id: "project",
              title: "Projekte identifizieren",
              desc: "Unterscheide Projekte auf einen Blick mit eigenen Symbolen, Namen, Beschreibungen und Farbthemen.",
            },
            {
              id: "files",
              title: "Dateiverwaltung",
              desc: "Verwalte Dateien direkt neben deinem Terminal — mit Typsymbolen, Dateigrößen, Tastaturnavigation, Bildvorschauen und Quick Look per Leertaste.",
            },
            {
              id: "scripts-tasks",
              title: "Skripte und Aufgaben",
              desc: "Visualisiere NPM Scripts, Gradle Tasks, Cargo- und CMake-Befehle und führe sie mit einem Klick aus.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Visualisiere gängige Git-Aktionen und erstelle Commit-Nachrichten mit einem Klick.\nBetrieben durch eine lokale Agent CLI — kein API-Schlüssel erforderlich.",
            },
            {
              id: "launchers",
              title: "Schnellstarter",
              desc: "Starte die für dein Projekt benötigten Werkzeuge schnell.\nÖffne Apps, Dokumente, Terminals oder Ordner mit einem Klick.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Besser entwickeln im Web",
          description: "Du entwickelst ein Webprojekt? Diese Funktionen wirst du lieben.",
          cards: [
            {
              id: "package-manager",
              title: "Paketmanager-Integration",
              desc: "Bearbeite Abhängigkeitsversionen schnell, erkenne NPM Scripts und finde die Ports von Entwicklungsservern.",
            },
            {
              id: "dev-server",
              title: "Erkennung von Entwicklungsservern",
              desc: "Behalte jederzeit den Überblick über deine laufenden Dienste.\nPorts und Vorschau-Links auf einen Blick.",
            },
            {
              id: "code-formatting",
              title: "Codeformatierung",
              desc: "Integrierte Unterstützung für die Codeformatierung mit oxfmt und Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Führe TS-, JS-, Python-, Go- und Rust-Dateien mit einem Klick aus.",
            },
            {
              id: "image-viewer",
              title: "Leistungsstarker Bildbetrachter",
              desc: "Ein voll ausgestatteter Bildbetrachter mit Metadaten, Linealen, Pixelfeedback, Vergleichsmodus und mehr.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Komprimiere, skaliere und konvertiere Bilder mit Exportfunktionen auf dem Niveau professioneller Designwerkzeuge.",
            },
          ],
        },
      ],
    },

    fr: {
      name: "Français",
      page: {
        tagline:
          "Un espace de travail de terminal accessible aux débutants, réunissant terminal, agents IA, gestion des fichiers, édition et exécution du code, Git, traitement d’images et bien plus — natif, gratuit et open source.",
        taglineShort: "Espace de travail de terminal",
        metaDesc:
          "Un espace de travail de terminal natif, gratuit et open source pour macOS, avec agents IA, gestion des fichiers, édition et exécution du code, Git, traitement d’images et bien plus.",
      },
      ui: {
        download: "Télécharger",
        viewOnGithub: "Voir sur GitHub",
        langSwitchAria: "Choisir la langue",
        otherProducts: "Autres produits",
        moreProducts: "Plus de produits",
        productLinks: "Produit",
        contact: "Contact",
        officialWebsite: "Site web",
        docs: "Documentation",
        changelog: "Journal des modifications",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Déplacez le curseur librement",
              desc: "Déplacez-vous et modifiez votre contenu aussi naturellement que dans un éditeur de texte.",
            },
          ],
        },
        {
          id: "projects",
          title: "Un espace de travail pensé pour vos projets",
          description:
            "Faites tout sans quitter votre espace de travail de terminal — CLI, agents IA, gestion des fichiers et Git.",
          cards: [
            {
              id: "agent",
              title: "Travaillez avec plusieurs agents IA en parallèle",
              desc: "Utilisez plusieurs onglets et volets pour faire travailler plusieurs agents IA ensemble.",
            },
            {
              id: "project",
              title: "Identification des projets",
              desc: "Repérez vos projets d’un coup d’œil grâce aux icônes, noms, descriptions et thèmes de couleurs personnalisés.",
            },
            {
              id: "files",
              title: "Gestion des fichiers",
              desc: "Gérez vos fichiers juste à côté du terminal, avec icônes de type, tailles, navigation au clavier, aperçus d’images et Quick Look avec la barre d’espace.",
            },
            {
              id: "scripts-tasks",
              title: "Scripts et tâches",
              desc: "Visualisez les commandes NPM Scripts, Gradle Tasks, Cargo et CMake, puis exécutez-les en un clic.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Visualisez les opérations Git courantes et générez des messages de commit en un clic.\nPropulsé par un Agent CLI local, sans clé API.",
            },
            {
              id: "launchers",
              title: "Lanceurs rapides",
              desc: "Lancez rapidement les outils nécessaires à votre projet.\nOuvrez des applications, documents, terminaux ou dossiers en un clic.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Une meilleure expérience pour le développement web",
          description: "Vous développez un projet web ? Vous allez adorer ces fonctionnalités.",
          cards: [
            {
              id: "package-manager",
              title: "Intégration des gestionnaires de paquets",
              desc: "Modifiez rapidement les versions des dépendances, détectez les NPM Scripts et trouvez les ports des serveurs de développement.",
            },
            {
              id: "dev-server",
              title: "Détection des serveurs de développement",
              desc: "Sachez toujours où vos services sont en cours d’exécution.\nPorts et liens de prévisualisation au même endroit.",
            },
            {
              id: "code-formatting",
              title: "Formatage du code",
              desc: "Prise en charge intégrée du formatage avec oxfmt et Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Exécutez des fichiers TS, JS, Python, Go et Rust en un clic.",
            },
            {
              id: "image-viewer",
              title: "Puissant visualiseur d’images",
              desc: "Un visualiseur d’images complet avec métadonnées, règles, inspection des pixels, mode comparaison et bien plus.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Compressez, redimensionnez et convertissez vos images avec des contrôles d’export dignes des outils de design.",
            },
          ],
        },
      ],
    },

    ru: {
      name: "Русский",
      page: {
        tagline:
          "Удобное для начинающих терминальное рабочее пространство, объединяющее терминал, AI-агентов, управление файлами, редактирование и запуск кода, Git, обработку изображений и многое другое — нативное, бесплатное и с открытым исходным кодом.",
        taglineShort: "Терминальное рабочее пространство",
        metaDesc:
          "Нативное, бесплатное терминальное рабочее пространство с открытым исходным кодом для macOS: AI-агенты, управление файлами, редактирование и запуск кода, Git, обработка изображений и многое другое.",
      },
      ui: {
        download: "Скачать",
        viewOnGithub: "Открыть на GitHub",
        langSwitchAria: "Выбрать язык",
        otherProducts: "Другие продукты",
        moreProducts: "Больше продуктов",
        productLinks: "Продукт",
        contact: "Контакты",
        officialWebsite: "Сайт",
        docs: "Документация",
        changelog: "Журнал изменений",
      },
      sections: [
        {
          id: "fdl",
          cards: [
            {
              id: "free-cur",
              title: "Свободное перемещение курсора",
              desc: "Перемещайте курсор и редактируйте текст так же естественно, как в текстовом редакторе.",
            },
          ],
        },
        {
          id: "projects",
          title: "Рабочее пространство вокруг ваших проектов",
          description:
            "Выполняйте все задачи, не покидая терминальное рабочее пространство: CLI, AI-агенты, управление файлами и Git.",
          cards: [
            {
              id: "agent",
              title: "Параллельная работа с несколькими AI-агентами",
              desc: "Используйте несколько вкладок и панелей, чтобы AI-агенты работали вместе.",
            },
            {
              id: "project",
              title: "Идентификация проектов",
              desc: "Различайте проекты с первого взгляда благодаря пользовательским значкам, названиям, описаниям и цветовым темам.",
            },
            {
              id: "files",
              title: "Управление файлами",
              desc: "Управляйте файлами прямо рядом с терминалом: значки типов, размеры, навигация с клавиатуры, предпросмотр изображений и Quick Look по пробелу.",
            },
            {
              id: "scripts-tasks",
              title: "Скрипты и задачи",
              desc: "Визуализируйте команды NPM Scripts, Gradle Tasks, Cargo и CMake и запускайте их одним нажатием.",
            },
            {
              id: "git",
              title: "Git",
              desc: "Визуализируйте основные операции Git и создавайте сообщения коммитов одним нажатием.\nРаботает через локальный Agent CLI, API-ключ не требуется.",
            },
            {
              id: "launchers",
              title: "Быстрые средства запуска",
              desc: "Быстро запускайте нужные проекту инструменты.\nОткрывайте приложения, документы, терминалы или папки одним нажатием.",
            },
          ],
        },
        {
          id: "web-dev",
          title: "Более удобная веб-разработка",
          description: "Разрабатываете веб-проект? Вам понравятся эти возможности.",
          cards: [
            {
              id: "package-manager",
              title: "Интеграция с менеджерами пакетов",
              desc: "Быстро изменяйте версии зависимостей, находите NPM Scripts и порты серверов разработки.",
            },
            {
              id: "dev-server",
              title: "Поиск портов серверов разработки",
              desc: "Всегда знайте, где работают ваши сервисы.\nПорты и ссылки для предпросмотра — в одном месте.",
            },
            {
              id: "code-formatting",
              title: "Форматирование кода",
              desc: "Встроенная поддержка форматирования кода с помощью oxfmt и Prettier.",
            },
            {
              id: "script-runner",
              title: "Script Runner",
              desc: "Запускайте файлы TS, JS, Python, Go и Rust одним нажатием.",
            },
            {
              id: "image-viewer",
              title: "Мощный просмотрщик изображений",
              desc: "Полнофункциональный просмотрщик изображений с метаданными, линейками, анализом пикселей, режимом сравнения и многим другим.",
            },
            {
              id: "image-build",
              title: "Image Build",
              desc: "Сжимайте, изменяйте размер и конвертируйте изображения с экспортом профессионального уровня.",
            },
          ],
        },
      ],
    },
  },
};

export default i18n;
