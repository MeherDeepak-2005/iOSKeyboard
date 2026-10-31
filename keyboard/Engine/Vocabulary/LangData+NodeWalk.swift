import Foundation

extension LangData {
	// MARK: Node-handle trie walk (for glide beam search — O(1) per step, no re-walk)

	/// (label byte, child node index) for a node's children, label-sorted.
	func trieChildren(ofNode node: Int) -> [(label: UInt8, node: Int)] {
		guard hasTrie else { return [] }
		let first = Int(nodeU32(node, 2)), count = nodeByte(node, 1)
		return (0..<count).map { (UInt8(nodeByte(first + $0, 0)), first + $0) }
	}
	/// Allocation-free equivalent of `trieChildren(ofNode:)`, same order. The glide beam
	/// visits every hypothesis's children at each depth, so returning a fresh array there
	/// churned the heap on the decode's hot path; this iterates in place instead.
	@inline(__always)
	func forEachChild(ofNode node: Int, _ body: (_ label: UInt8, _ node: Int) -> Void) {
		guard hasTrie else { return }
		let first = Int(nodeU32(node, 2)), count = nodeByte(node, 1)
		for i in 0..<count { body(UInt8(nodeByte(first + i, 0)), first + i) }
	}
	/// The word ending at this node, or nil if the node is a non-terminal prefix.
	func trieWord(atNode node: Int) -> String? {
		let id = nodeWordID(node)
		return id == UInt32(Self.empty) ? nil : word(Int(Int32(bitPattern: id)))
	}
	/// Max corpus frequency anywhere in this node's subtree — lets
	/// glide's beam keep frequent-but-imperfect prefixes alive so context can rescue them.
	func trieMaxFreq(ofNode node: Int) -> UInt32 { nodeMaxFreq(node) }
}

/// Interpolated modified Kneser–Ney on retained pack entries. Historical context
/// totals include pruned successors, so denominators must sum retained counts.
/// No add-one or sparse-context heuristic is applied to observed vocabulary.
