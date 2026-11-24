import Foundation

extension Program {
    /// The insertion boundary uses the original table order, including the dragged rows.
    @discardableResult mutating func reorderSteps(ids:Set<String>,to boundary:Int)->Bool {
        guard !ids.isEmpty,(0...steps.count).contains(boundary),ids.isSubset(of:Set(steps.map(\.id))) else { return false }
        let moving=steps.filter { ids.contains($0.id) }
        let insertion=boundary-steps.prefix(boundary).filter { ids.contains($0.id) }.count
        var reordered=steps.filter { !ids.contains($0.id) }
        reordered.insert(contentsOf:moving,at:insertion)
        guard reordered.map(\.id) != steps.map(\.id) else { return false }
        steps=reordered;orderConfirmed=false
        return true
    }
}
