import SpriteKit
import ResourceKit

final class FSAnimationNode: SKNode {
    private let fs: FrameSequence
    private let frames: [ResourceLoader.RenderedFrame]
    private let spriteNode = SKSpriteNode()

    /// Команды кадров (CreateObject/DelObject/Sound...) — fon-анимации
    /// одноразовых объектов завершаются self-DelObject в последнем кадре
    var onCommand: ((FSCommand) -> Void)?

    /// If var == value — fon-анимации бывают стейт-машинами: попугай SCENA5
    /// каждый проход цикла проверяет переменные и переключает своё состояние
    var evaluateIf: ((String, String) -> Bool)?

    private var skipDepth = 0

    init(fs: FrameSequence, frames: [ResourceLoader.RenderedFrame]) {
        self.fs = fs
        self.frames = frames
        super.init()
        spriteNode.anchorPoint = CGPoint(x: 0, y: 1)
        addChild(spriteNode)
    }

    required init?(coder: NSCoder) { fatalError() }

    func play(loop: Bool) {
        spriteNode.removeAllActions()
        let sequence = buildActions()
        if loop {
            spriteNode.run(SKAction.repeatForever(SKAction.sequence(sequence)), withKey: "anim")
        } else {
            spriteNode.run(SKAction.sequence(sequence), withKey: "anim")
        }
    }

    func stop() {
        spriteNode.removeAllActions()
        spriteNode.texture = nil
    }

    private func buildActions() -> [SKAction] {
        // repeatForever гоняет одну и ту же цепочку — skipDepth сбрасываем
        // в начале каждого прохода
        var actions: [SKAction] = [SKAction.run { [weak self] in self?.skipDepth = 0 }]
        var frameIdx = 0
        for cmd in fs.commands {
            switch cmd {
            case .frame:
                guard frameIdx < frames.count else { continue }
                let frame = frames[frameIdx]
                frameIdx += 1
                let setTex = SKAction.run { [weak self] in
                    guard let self, self.skipDepth == 0 else { return }
                    self.spriteNode.texture = frame.texture
                    self.spriteNode.size = frame.texture.size()
                    self.spriteNode.position = CGPoint(x: frame.offsetX, y: -frame.offsetY)
                }
                actions.append(setTex)
            case .delay(let ms):
                let duration = Double(abs(ms)) / 1000.0 / GameSettings.speedFactor
                if duration > 0 {
                    actions.append(SKAction.wait(forDuration: duration))
                }
            case .ifCondition(let variable, let value):
                actions.append(SKAction.run { [weak self] in
                    guard let self else { return }
                    if self.skipDepth > 0 {
                        self.skipDepth += 1
                    } else if !(self.evaluateIf?(variable, value) ?? true) {
                        self.skipDepth = 1
                    }
                })
            case .endIf:
                actions.append(SKAction.run { [weak self] in
                    guard let self, self.skipDepth > 0 else { return }
                    self.skipDepth -= 1
                })
            default:
                actions.append(SKAction.run { [weak self] in
                    guard let self, self.skipDepth == 0 else { return }
                    self.onCommand?(cmd)
                })
            }
        }
        if actions.isEmpty {
            actions.append(SKAction.wait(forDuration: 0.1))
        }
        return actions
    }
}
