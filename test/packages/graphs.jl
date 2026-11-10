# Graphs.jl: undirected and directed graphs (made by adding vertices and edges, and by the generators), searches and shortest paths, connectivity, spanning trees, centrality, matrices and coloring.
using Graphs

path_chord(n) = (g = SimpleGraph(n); for i in 1:n-1; add_edge!(g, i, i + 1); end; add_edge!(g, 1, n); g)
ring_chord(n) = (g = SimpleDiGraph(n); for i in 1:n-1; add_edge!(g, i, i + 1); end; add_edge!(g, n, 1); add_edge!(g, 2, 5); g)
function edge_sum(g)
    s = 0
    for e in edges(g)
        s += src(e) * 10 + dst(e)
    end
    return s
end

@testset "Graphs.jl" begin
    @testset "Building and querying" begin
        check_cases([
            "nv, ne"                => () -> (g = path_chord(opaque(6)); nv(g) * 100 + ne(g)),
            "neighbors, degree"     => () -> (g = path_chord(opaque(6)); sum(neighbors(g, 1)) * 10 + degree(g, 1)),
            "has_edge"              => () -> (g = path_chord(opaque(6)); Int(has_edge(g, 1, 2)) + 10 * Int(has_edge(g, 1, 4))),
            "rem_edge!"             => () -> (g = path_chord(opaque(6)); rem_edge!(g, 1, 2); ne(g) * 10 + Int(has_edge(g, 1, 2))),
            "add_vertex!"           => () -> (g = path_chord(opaque(4)); add_vertex!(g); add_edge!(g, 5, 1); nv(g) * 10 + ne(g)),
            "degrees"               => () -> (g = path_chord(opaque(6)); sum(degree(g)) + maximum(degree(g))),
            "from a list of edges"  => () -> (g = SimpleGraph([Edge(1, 2), Edge(2, 3), Edge(opaque(3), 4)]); nv(g) * 10 + ne(g)),
            "iterating the edges"   => () -> edge_sum(path_chord(opaque(5))),
            "induced_subgraph"      => () -> ((sg, vmap) = induced_subgraph(path_chord(opaque(8)), [1, 2, 3, 4]); nv(sg) * 10 + ne(sg)),
            "in and out degrees"    => () -> (g = ring_chord(opaque(6)); sum(indegree(g)) * 10 + maximum(outdegree(g))),
            "generators"            => () -> (ne(path_graph(opaque(5))) * 100 + ne(cycle_graph(5)) * 10 + ne(star_graph(5))),
            "complete_graph, grid"  => () -> (ne(complete_graph(opaque(6))) * 100 + nv(grid([3, 3]))),
            "erdos_renyi with a seed" => () -> ne(erdos_renyi(opaque(20), 40; seed = 1)),
        ])
    end

    @testset "Searches and shortest paths" begin
        check_cases([
            "bfs_tree"              => () -> (t = bfs_tree(path_chord(opaque(8)), 1); ne(t) * 10 + nv(t)),
            "dfs_tree"              => () -> ne(dfs_tree(path_chord(opaque(8)), 1)),
            "gdistances"            => () -> sum(gdistances(path_chord(opaque(8)), 1)),
            "dijkstra"              => () -> Int(sum(dijkstra_shortest_paths(path_chord(opaque(8)), 1).dists)),
            "dijkstra with weights" => () -> Int(sum(dijkstra_shortest_paths(path_chord(opaque(6)), 1, fill(2.0, 6, 6)).dists)),
            "bellman_ford"          => () -> Int(sum(bellman_ford_shortest_paths(ring_chord(opaque(6)), 1).dists)),
            "floyd_warshall"        => () -> Int(sum(floyd_warshall_shortest_paths(path_chord(opaque(6))).dists)),
            "a_star"                => () -> length(a_star(path_chord(opaque(8)), 1, 5)),
            "enumerate_paths"       => () -> length(first(enumerate_paths(dijkstra_shortest_paths(path_chord(opaque(8)), 1), 5))),
            "random walk"           => () -> length(randomwalk(path_chord(opaque(8)), 1, 10)),
        ])
    end

    @testset "Connectivity and structure" begin
        check_cases([
            "connected_components"  => () -> (g = SimpleGraph(opaque(6)); add_edge!(g, 1, 2); add_edge!(g, 3, 4); length(connected_components(g))),
            "is_connected"          => () -> Int(is_connected(path_chord(opaque(5)))),
            "strongly_connected_components" => () -> length(strongly_connected_components(ring_chord(opaque(6)))),
            "topological_sort"      => () -> (g = SimpleDiGraph(opaque(5)); add_edge!(g, 1, 2); add_edge!(g, 2, 3); add_edge!(g, 1, 4); add_edge!(g, 4, 5); sum(topological_sort(g) .* [1, 2, 3, 4, 5])),
            "is_cyclic"             => () -> Int(is_cyclic(ring_chord(opaque(5)))),
            "is_bipartite"          => () -> Int(is_bipartite(cycle_graph(opaque(6)))),
            "kruskal_mst, prim_mst" => () -> length(kruskal_mst(path_chord(opaque(8)))) * 10 + length(prim_mst(path_chord(opaque(8)))),
            "maximal_cliques"       => () -> length(maximal_cliques(complete_graph(opaque(5)))),
            "greedy_color"          => () -> greedy_color(complete_graph(opaque(4))).num_colors,
            "label_propagation"     => () -> ((l, _) = label_propagation(complete_graph(opaque(6))); length(unique(l))),
            "core_number"           => () -> sum(core_number(complete_graph(opaque(5)))),
            "diameter, radius"      => () -> (g = path_chord(opaque(8)); diameter(g) * 10 + radius(g)),
        ])
    end

    @testset "Centrality and matrices" begin
        check_cases([
            "pagerank"              => () -> r6(sum(pagerank(ring_chord(opaque(6))))),
            "betweenness_centrality" => () -> r6(sum(betweenness_centrality(path_chord(opaque(6))))),
            "eigenvector_centrality" => () -> r6(sum(eigenvector_centrality(path_chord(opaque(6))))),
            "closeness_centrality"  => () -> r6(sum(closeness_centrality(path_chord(opaque(6))))),
            "global_clustering_coefficient" => () -> r6(global_clustering_coefficient(complete_graph(opaque(5)))),
            "adjacency_matrix"      => () -> sum(adjacency_matrix(path_chord(opaque(5)))),
            "laplacian_matrix"      => () -> sum(laplacian_matrix(path_chord(opaque(5)))),
        ])
    end
end
