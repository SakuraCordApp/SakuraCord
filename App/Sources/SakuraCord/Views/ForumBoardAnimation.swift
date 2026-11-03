import AppKit
import QuartzCore

extension ForumBoardView {
    /// Boards that differ wholesale (list and gallery, or two queries'
    /// results) cross-fade rather than glide. A fade is also what Reduce
    /// Motion asks for, so it always runs.
    func crossFadeBoard() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        cardsLayer.add(fade, forKey: "morph")
    }

    /// Reduce Motion replaces travel and scaling with cross-fades.
    var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func animateMove(_ card: ForumBoardCard, from oldFrame: CGRect) {
        if reducesMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 1
            fade.duration = 0.22
            card.layer.add(fade, forKey: "move")
            return
        }
        let spring = Self.spring("position")
        spring.fromValue = NSValue(point: CGPoint(
            x: oldFrame.minX + oldFrame.width * card.layer.anchorPoint.x,
            y: oldFrame.minY + oldFrame.height * card.layer.anchorPoint.y
        ))
        spring.toValue = NSValue(point: card.layer.position)
        card.layer.add(spring, forKey: "move")
    }

    /// A resize that changes the gallery's column count moves cards to new
    /// slots. Each glides from where it was, already at its new size so its
    /// bitmap fits. The motion is additive, an offset decaying to zero, so a
    /// resize still under way keeps moving the frame without a jump when the
    /// motion ends.
    func animateReflow(_ card: ForumBoardCard, from oldFrame: CGRect) {
        let frame = card.frame
        guard oldFrame.origin != frame.origin else { return }
        let spring = Self.spring("position")
        spring.isAdditive = true
        spring.fromValue = NSValue(point: CGPoint(x: oldFrame.minX - frame.minX, y: oldFrame.minY - frame.minY))
        spring.toValue = NSValue(point: .zero)
        card.layer.add(spring, forKey: nil)
    }

    static let glideDuration: CFTimeInterval = 0.55

    private static func spring(_ keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.damping = 26
        spring.stiffness = 260
        spring.mass = 1
        spring.duration = min(spring.settlingDuration, glideDuration)
        return spring
    }

    /// A card inserted live rises into place.
    func animateEntrance(_ card: ForumBoardCard) {
        let group = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let lift = CABasicAnimation(keyPath: "transform")
        lift.fromValue = NSValue(caTransform3D: CATransform3DConcat(
            CATransform3DMakeScale(0.97, 0.97, 1),
            CATransform3DMakeTranslation(0, InterfaceScale.metric(8), 0)
        ))
        lift.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        group.animations = reducesMotion ? [fade] : [fade, lift]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        card.layer.add(group, forKey: "entrance")
    }

    /// Placeholders appear only if loading lasts long enough to notice, so a
    /// fast load never flashes skeletons.
    func animatePlaceholderEntrance(_ card: ForumBoardCard) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.beginTime = CACurrentMediaTime() + 0.12
        fade.fillMode = .backwards
        card.layer.add(fade, forKey: "placeholder-entrance")
    }

    func animateExit(_ card: ForumBoardCard) {
        exitingCards[ObjectIdentifier(card)] = card
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // The card owns its layer until the fade ends, unless the
                // board already recycled it.
                guard let self else {
                    card.layer.removeFromSuperlayer()
                    return
                }
                guard self.exitingCards.removeValue(forKey: ObjectIdentifier(card)) != nil else { return }
                self.recycle(card)
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = card.layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.18
        card.layer.opacity = 0
        card.layer.add(fade, forKey: "exit")
        CATransaction.commit()
    }

    /// Ends exit fades at once, so a new query or layout never draws over
    /// cards still leaving the old one.
    func cancelExits() {
        let exiting = exitingCards.values
        exitingCards.removeAll()
        for card in exiting { recycle(card) }
    }
}
